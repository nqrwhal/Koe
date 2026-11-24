import FluidAudio
import Foundation

/// Live dictation session that streams audio while the key is held:
/// - **Native Streaming (ANE Solo + Parakeet Unified Streaming)**: feeds audio continuously directly
///   into the stateful RNNT encoder/decoder with zero pause-chopping, preventing truncated sentences.
/// - **Conservative Hybrid Segmentation**: only splits long monologues on extended pauses (>= 1.4s
///   after >= 10s of speech, or disables cuts under 30s when `wholeDictationOnly` is on), and heals
///   seams using syntactic rules plus calibrated LLM continuation checks.
final class LiveTranscription {
    struct Outcome {
        let text: String
        let segments: [Pipeline.Result]
        let tailMs: Int
    }

    private static let block = VadManager.chunkSize  // 4096 samples = 256 ms at 16 kHz
    private static let silenceProbability: Float = 0.25

    private static let incompleteEndWords: Set<String> = [
        "to", "for", "with", "in", "on", "of", "at", "by", "from", "into", "onto", "about",
        "between", "through", "against", "without", "within", "the", "a", "an", "my", "your",
        "our", "their", "his", "her", "its", "this", "that", "these", "those", "we", "i",
        "you", "they", "he", "she", "it", "can", "could", "will", "would", "should", "may",
        "might", "must", "is", "are", "was", "were", "be", "been", "being", "have", "has",
        "had", "do", "does", "did", "and", "or", "but", "so", "if", "when", "while",
        "because", "since", "although", "though", "unless", "until", "which", "who", "where",
    ]

    private static let commaJoinConnectors: Set<String> = [
        "but", "so", "which", "whereas", "although", "though", "unless", "while",
    ]

    private static let clauseConnectors: Set<String> = [
        "but", "and", "or", "so", "because", "while", "which", "whereas", "although", "though",
        "unless", "until", "that",
    ]

    private let pipeline: Pipeline
    private let vad: VadManager?
    private let options: TuningOptions
    private let nativeStreaming: Bool
    private let onPartial: (@Sendable (String) -> Void)?

    private let minSegment: Int
    private let maxSegment: Int
    private let pauseBlocks: Int

    private let input: AsyncStream<[Float]>
    private let feed: AsyncStream<[Float]>.Continuation
    private var consumer: Task<Void, Never>?

    // Owned by the consumer task until `finish` / `cancel` awaits it.
    private var samples: [Float] = []
    private var probabilities: [Float] = []
    private var segmentStart = 0
    private var pending: Task<[Piece], Error>?
    private var streamFedSamples = 0
    private var streamStarted = false

    private struct Piece {
        let result: Pipeline.Result
        let continuesPrevious: Bool
        let insertCommaOnJoin: Bool
    }

    init(
        pipeline: Pipeline,
        vad: VadManager?,
        options: TuningOptions,
        nativeStreaming: Bool,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) {
        self.pipeline = pipeline
        self.vad = vad
        self.options = options
        self.nativeStreaming = nativeStreaming
        self.onPartial = onPartial

        if options.wholeDictationOnly {
            self.minSegment = 30 * 16_000
            self.maxSegment = 30 * 16_000
        } else {
            self.minSegment = max(6, Int(round(options.minSegmentSeconds))) * 16_000
            self.maxSegment = 28 * 16_000
        }
        self.pauseBlocks = max(2, Int(round(options.pauseThresholdSeconds / 0.256)))

        (input, feed) = AsyncStream.makeStream(of: [Float].self)
        consumer = Task { await consume() }
    }

    func append(_ chunk: [Float]) {
        feed.yield(chunk)
    }

    func stop() async {
        feed.finish()
        await consumer?.value
    }

    func cancel() async {
        feed.finish()
        await consumer?.value
        if nativeStreaming && streamStarted {
            await pipeline.cancelBaseStream()
            streamStarted = false
        }
    }

    func finish(_ recording: [Float]) async throws -> Outcome {
        await stop()
        let released = Date()

        if nativeStreaming {
            if !streamStarted {
                let result = try await pipeline.transcribe(recording, options: options)
                return Outcome(
                    text: result.text,
                    segments: [result],
                    tailMs: Int(Date().timeIntervalSince(released) * 1000)
                )
            }
            // Append any tail samples from `recording` not yet forwarded (e.g. if feed missed nothing, delta is 0).
            if recording.count > streamFedSamples {
                let tail = Array(recording[streamFedSamples...])
                try await pipeline.appendBaseStream(tail)
                streamFedSamples = recording.count
            }
            let rawBase = try await pipeline.finishBaseStream()
            streamStarted = false
            let tailMs = Int(Date().timeIntervalSince(released) * 1000)
            let result = await pipeline.finishNativeStreamResult(rawBase: rawBase, baseMs: tailMs, options: options)
            return Outcome(
                text: result.text,
                segments: [result],
                tailMs: Int(Date().timeIntervalSince(released) * 1000)
            )
        }

        let tail = Array(recording[min(segmentStart, recording.count)...])
        var pieces = try await pending?.value ?? []
        let tailSlice = probabilities[min(segmentStart / Self.block, probabilities.count)...]
        let tailSpoken = !tail.isEmpty && (vad == nil || Self.hasSpeech(tailSlice) || Self.hasAudibleEnergy(tail))
        if tailSpoken || pieces.isEmpty {
            pieces.append(try await Self.transcribe(tail.isEmpty ? recording : tail, after: pieces, with: pipeline, options: options))
        }
        let joined = Self.join(pieces)
        let finalCleaned = pipeline.cleanFinalText(joined, options: options)
        return Outcome(
            text: finalCleaned,
            segments: pieces.map(\.result),
            tailMs: Int(Date().timeIntervalSince(released) * 1000)
        )
    }

    /// Waits for segments already cut during speech (eval harness helper).
    func settle() async {
        _ = try? await pending?.value
    }

    private func consume() async {
        if nativeStreaming {
            do {
                try await pipeline.beginBaseStream()
                streamStarted = true
            } catch {
                log.error("beginBaseStream failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            var pendingAudio: [Float] = []
            for await chunk in input {
                pendingAudio.append(contentsOf: chunk)
                if pendingAudio.count >= 8_000 {
                    let batch = pendingAudio
                    pendingAudio.removeAll(keepingCapacity: true)
                    try? await pipeline.appendBaseStream(batch)
                    streamFedSamples += batch.count
                    try? await pipeline.processBaseStream()
                    if let onPartial {
                        let partial = await pipeline.partialBaseStreamText()
                        if !partial.isEmpty { onPartial(partial) }
                    }
                }
            }
            if !pendingAudio.isEmpty {
                try? await pipeline.appendBaseStream(pendingAudio)
                streamFedSamples += pendingAudio.count
            }
            return
        }

        var state = VadStreamState.initial()
        for await chunk in input {
            samples += chunk
            guard let vad else { continue }
            while (probabilities.count + 1) * Self.block <= samples.count {
                let start = probabilities.count * Self.block
                let result = try? await vad.processStreamingChunk(Array(samples[start..<start + Self.block]), state: state)
                if let result { state = result.state }
                probabilities.append(result?.probability ?? 1)
                cutIfReady()
            }
        }
        if let vad, samples.count > probabilities.count * Self.block {
            let start = probabilities.count * Self.block
            var trailingBlock = Array(samples[start...])
            if trailingBlock.count < Self.block {
                trailingBlock += [Float](repeating: 0, count: Self.block - trailingBlock.count)
            }
            let result = try? await vad.processStreamingChunk(trailingBlock, state: state)
            probabilities.append(result?.probability ?? 1)
        }
    }

    private func cutIfReady() {
        let end = probabilities.count * Self.block
        let length = end - segmentStart
        guard length >= minSegment else { return }

        let firstBlock = segmentStart / Self.block
        var silent = 0
        while firstBlock + silent < probabilities.count && probabilities[probabilities.count - 1 - silent] < Self.silenceProbability {
            silent += 1
        }
        if silent >= pauseBlocks {
            let cut = end - silent * Self.block / 2
            if Self.hasSpeech(probabilities[firstBlock..<probabilities.count - silent]) {
                submit(upTo: cut)
            } else {
                segmentStart = cut
            }
        } else if length >= maxSegment {
            let first = max(segmentStart / Self.block + 1, probabilities.count - 24)
            let quietest = (first..<probabilities.count).min { probabilities[$0] < probabilities[$1] } ?? probabilities.count - 1
            submit(upTo: quietest * Self.block + Self.block / 2)
        }
    }

    private static func hasSpeech(_ blocks: ArraySlice<Float>) -> Bool {
        blocks.contains { $0 >= silenceProbability }
    }

    private static func hasAudibleEnergy(_ samples: [Float]) -> Bool {
        samples.contains { abs($0) >= 0.015 }
    }

    private func submit(upTo cut: Int) {
        let segment = Array(samples[segmentStart..<cut])
        segmentStart = cut
        let previous = pending
        let pipeline = pipeline
        let opts = options
        pending = Task {
            let done = try await previous?.value ?? []
            return done + [try await Self.transcribe(segment, after: done, with: pipeline, options: opts)]
        }
    }

    private static func transcribe(
        _ audio: [Float],
        after done: [Piece],
        with pipeline: Pipeline,
        options: TuningOptions
    ) async throws -> Piece {
        let previous = done.last?.result.text
        let result = try await pipeline.transcribe(audio, context: previous, options: options)
        var continues = false
        var insertComma = false
        if let previous, previous.hasSuffix("."), !result.text.isEmpty {
            let decision = await resolveSeam(previous: previous, next: result.text, with: pipeline)
            continues = decision.join
            insertComma = decision.insertComma
        }
        return Piece(result: result, continuesPrevious: continues, insertCommaOnJoin: insertComma)
    }

    private static func resolveSeam(
        previous: String,
        next: String,
        with pipeline: Pipeline
    ) async -> (join: Bool, insertComma: Bool) {
        let prevLast = previous.split(whereSeparator: \.isWhitespace).last?
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,?!;:\"'"))
            .lowercased() ?? ""
        let nextFirst = next.split(whereSeparator: \.isWhitespace).first?
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,?!;:\"'"))
            .lowercased() ?? ""

        // Hard syntactic continuation: dangling preposition, article, pronoun, auxiliary, or conjunction.
        if incompleteEndWords.contains(prevLast) {
            return (true, false)
        }

        let isConnector = clauseConnectors.contains(nextFirst)
        let shouldJoin = await pipeline.continues(previous, next, relaxed: isConnector)
        if shouldJoin {
            return (true, commaJoinConnectors.contains(nextFirst))
        }
        return (false, false)
    }

    private static func join(_ pieces: [Piece]) -> String {
        var out = ""
        for piece in pieces where !piece.result.text.isEmpty {
            var next = piece.result.text
            if let last = out.last {
                if piece.continuesPrevious && last == "." {
                    out.removeLast()
                    if piece.insertCommaOnJoin && !out.hasSuffix(",") {
                        out += ","
                    }
                    next = lowercasingFirstWord(next)
                } else if !".?!".contains(last) {
                    next = lowercasingFirstWord(next)
                }
            }
            out += out.isEmpty ? next : " " + next
        }
        return out
    }

    private static func lowercasingFirstWord(_ text: String) -> String {
        let word = text.prefix { $0.isLetter || $0 == "'" }
        guard !word.isEmpty, word != "I", !word.hasPrefix("I'"), word.dropFirst().allSatisfy(\.isLowercase) else { return text }
        return text.prefix(1).lowercased() + text.dropFirst()
    }
}
