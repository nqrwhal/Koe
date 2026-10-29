import FluidAudio

/// Bark 3.0 Clean (a Parakeet TDT fine-tune for dictation) running on the Neural Engine.
actor Transcriber {
    private let asr = AsrManager(config: .default)
    private let converter = AudioConverter()
    private var decoderLayers = 2

    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        let models = try await AsrModels.downloadAndLoad(version: .bark3Clean) { progress($0.fractionCompleted) }
        try await asr.loadModels(models)
        decoderLayers = await asr.decoderLayerCount
        // Warm-up so the first real dictation doesn't pay for Core ML compilation.
        _ = try await transcribe([Float](repeating: 0, count: 16_000), sampleRate: 16_000)
    }

    func transcribe(_ samples: [Float], sampleRate: Double) async throws -> String {
        var audio = sampleRate == 16_000 ? samples : try converter.resample(samples, from: sampleRate)
        // The model rejects clips under one second; pad short ones with silence.
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await asr.transcribe(audio, decoderState: &state)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Dropped fillers ("Um, so…") can leave the first word lowercase.
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
