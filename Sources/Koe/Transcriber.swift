import AVFoundation
import FluidAudio
import Foundation

/// Base ANE speech recognizer supporting Parakeet Unified 0.6B (streaming or 15s batch)
/// and legacy Bark 3.0 Clean, plus optional FluidAudio CTC vocabulary boosting.
actor Transcriber {
    enum Backend: String, Sendable {
        case parakeetUnifiedStreaming = "unified-stream"
        case parakeetUnifiedBatch = "unified-batch"
        case bark3Clean = "bark"
    }

    private static let pcm16kFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private let converter = AudioConverter()
    private var backend: Backend = .parakeetUnifiedStreaming
    private var streamingUnified: StreamingUnifiedAsrManager?
    private var batchUnified: UnifiedAsrManager?
    private var barkManager: AsrManager?
    private var barkDecoderLayers = 2
    private var ctcModels: CtcModels?
    private var configuredVocabKey: String?
    private var streamAppendedSamples = 0

    var loadedBackend: Backend? {
        if streamingUnified != nil { return .parakeetUnifiedStreaming }
        if batchUnified != nil { return .parakeetUnifiedBatch }
        if barkManager != nil { return .bark3Clean }
        return nil
    }

    var isLoaded: Bool { loadedBackend != nil }
    var hasVocabularyBoosting: Bool { configuredVocabKey != nil }

    /// Backwards-compatible default loader (used by iOS target and simple callers).
    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        #if os(iOS)
        try await load(backend: .bark3Clean, ctcTerms: nil, progress: progress)
        #else
        try await load(backend: .parakeetUnifiedStreaming, ctcTerms: nil, progress: progress)
        #endif
    }

    func load(
        backend: Backend,
        ctcTerms: [String]? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let validCTCTerms = (ctcTerms ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 && !$0.contains("/") }
        let usableCTC = (backend == .parakeetUnifiedStreaming || backend == .parakeetUnifiedBatch) && !validCTCTerms.isEmpty
        let needsDetachCTC = !usableCTC && configuredVocabKey != nil

        if loadedBackend != backend || needsDetachCTC {
            await cleanup()
            self.backend = backend

            switch backend {
            case .parakeetUnifiedStreaming:
                let config = UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 1)
                let manager = StreamingUnifiedAsrManager(config: config, encoderPrecision: .int8)
                try await manager.loadModels(progressHandler: { progress($0.fractionCompleted) })
                streamingUnified = manager
                // Warm-up so CoreML compiles ANE plans before the first dictation.
                _ = try await transcribe([Float](repeating: 0, count: 16_000), sampleRate: 16_000)

            case .parakeetUnifiedBatch:
                let manager = UnifiedAsrManager(encoderPrecision: .int8)
                try await manager.loadModels(progressHandler: { progress($0.fractionCompleted) })
                batchUnified = manager
                _ = try await transcribe([Float](repeating: 0, count: 16_000), sampleRate: 16_000)

            case .bark3Clean:
                let manager = AsrManager(config: .default)
                let models = try await AsrModels.downloadAndLoad(version: .bark3Clean) { progress($0.fractionCompleted) }
                try await manager.loadModels(models)
                barkDecoderLayers = await manager.decoderLayerCount
                barkManager = manager
                _ = try await transcribe([Float](repeating: 0, count: 16_000), sampleRate: 16_000)
            }
        }

        if usableCTC {
            await configureVocabularyBoosting(terms: ctcTerms ?? [])
        }
    }

    func configureVocabularyBoosting(terms: [String]) async {
        guard backend == .parakeetUnifiedStreaming || backend == .parakeetUnifiedBatch else { return }
        let usable = Array(Set(terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && !$0.contains("/") })).sorted()
        guard !usable.isEmpty else { return }

        let key = "\(backend.rawValue)|" + usable.joined(separator: "\u{1F}")
        if key == configuredVocabKey { return }

        do {
            if ctcModels == nil {
                ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            }
            guard let ctcModels else { return }
            let vocabTerms = usable.filter { $0.count >= 4 }.map { CustomVocabularyTerm(text: $0, weight: 8.0) }
            guard !vocabTerms.isEmpty else { return }
            let context = CustomVocabularyContext(terms: vocabTerms, minSimilarity: 0.68, minTermLength: 4)
            if let streamingUnified {
                try await streamingUnified.configureVocabularyBoosting(vocabulary: context, ctcModels: ctcModels)
            }
            if let batchUnified {
                try await batchUnified.configureVocabularyBoosting(vocabulary: context, ctcModels: ctcModels)
            }
            configuredVocabKey = key
        } catch {
            log.error("CTC vocabulary boosting setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func disableVocabularyBoosting() async {
        configuredVocabKey = nil
        ctcModels = nil
        // FluidAudio doesn't expose a clearVocabularyBoosting method, so reload if needed later.
    }

    // MARK: - Streaming Session (Parakeet Unified Streaming)

    var supportsStreamingSession: Bool {
        streamingUnified != nil
    }

    func beginStream() async throws {
        guard let streamingUnified else { throw ASRError.notInitialized }
        try await streamingUnified.reset()
        streamAppendedSamples = 0
    }

    func appendStreamSamples(_ samples: [Float], sampleRate: Double = 16_000) async throws {
        guard let streamingUnified, !samples.isEmpty else { return }
        let audio = sampleRate == 16_000 ? samples : try converter.resample(samples, from: sampleRate)
        guard !audio.isEmpty, let buffer = makeBuffer(audio) else { return }
        try await streamingUnified.appendAudio(buffer)
        streamAppendedSamples += audio.count
    }

    func processStream() async throws {
        guard let streamingUnified else { return }
        try await streamingUnified.processBufferedAudio()
    }

    func partialStreamText() async -> String {
        guard let streamingUnified else { return "" }
        return await streamingUnified.getPartialTranscript()
    }

    func finishStream() async throws -> String {
        guard let streamingUnified else { throw ASRError.notInitialized }
        if streamAppendedSamples > 0 && streamAppendedSamples < 16_000 {
            let pad = [Float](repeating: 0, count: 16_000 - streamAppendedSamples)
            if let padBuf = makeBuffer(pad) {
                try await streamingUnified.appendAudio(padBuf)
            }
        }
        let raw = try await streamingUnified.finish()
        try await streamingUnified.reset()
        streamAppendedSamples = 0
        return Self.cleanOutput(raw)
    }

    func cancelStream() async {
        streamAppendedSamples = 0
        try? await streamingUnified?.reset()
    }

    // MARK: - Batch Transcription

    func transcribe(_ samples: [Float], sampleRate: Double) async throws -> String {
        var audio = sampleRate == 16_000 ? samples : try converter.resample(samples, from: sampleRate)
        if audio.isEmpty { return "" }
        if audio.count < 16_000 {
            audio += [Float](repeating: 0, count: 16_000 - audio.count)
        }

        switch backend {
        case .parakeetUnifiedStreaming:
            guard let streamingUnified else { throw ASRError.notInitialized }
            try await streamingUnified.reset()
            let chunkSize = 16_000
            for start in stride(from: 0, to: audio.count, by: chunkSize) {
                let slice = Array(audio[start..<min(start + chunkSize, audio.count)])
                if let buffer = makeBuffer(slice) {
                    try await streamingUnified.appendAudio(buffer)
                    try await streamingUnified.processBufferedAudio()
                }
            }
            let raw = try await streamingUnified.finish()
            try await streamingUnified.reset()
            return Self.cleanOutput(raw)

        case .parakeetUnifiedBatch:
            guard let batchUnified else { throw ASRError.notInitialized }
            let raw = try await batchUnified.transcribe(audio)
            return Self.cleanOutput(raw)

        case .bark3Clean:
            guard let barkManager else { throw ASRError.notInitialized }
            var state = TdtDecoderState.make(decoderLayers: barkDecoderLayers)
            let result = try await barkManager.transcribe(audio, decoderState: &state)
            return Self.cleanOutput(result.text)
        }
    }

    func cleanup() async {
        await streamingUnified?.cleanup()
        await batchUnified?.cleanup()
        await barkManager?.cleanup()
        streamingUnified = nil
        batchUnified = nil
        barkManager = nil
        ctcModels = nil
        configuredVocabKey = nil
        streamAppendedSamples = 0
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.pcm16kFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    private static func cleanOutput(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
