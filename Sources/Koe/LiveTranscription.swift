import FluidAudio
import Foundation

/// Transcribes a dictation in pieces while the key is still held, so that on release only the
/// audio after the last cut is left. Silero VAD scores each 256 ms block; once a segment is long
/// enough and the speaker pauses, it is cut in the middle of the pause and sent through the
/// pipeline in the background (the same idea as Handy's chunked mode). Short dictations are never
/// cut and take the plain whole-recording path.
///
/// Both recognizers end every piece with a period, so a pause mid-sentence would leave
/// "a passage from. A book now." Each seam after a period is checked with Gemma, which sees both
/// sides (in the background for all but the last seam), and rejoined when the sentence continues.
final class LiveTranscription {
    struct Outcome {
        let text: String
        let segments: [Pipeline.Result]
        let tailMs: Int  // time spent after release
    }

    private static let block = VadManager.chunkSize  // 4096 samples = 256 ms at 16 kHz
    private static let minSegment = 3 * 16_000
    private static let maxSegment = 20 * 16_000
    private static let pauseBlocks = 2  // ≥ 512 ms; shorter pauses cut mid-sentence ("from. A book")
    private static let silenceProbability: Float = 0.35

    private let pipeline: Pipeline
    private let vad: VadManager
    private let input: AsyncStream<[Float]>
    private let feed: AsyncStream<[Float]>.Continuation
    private var consumer: Task<Void, Never>?

    // Owned by the consumer task until `finish` cancels and awaits it.
    private var samples: [Float] = []
    private var probabilities: [Float] = []
    private var segmentStart = 0
    private var pending: Task<[Piece], Error>?

    private struct Piece {
        let result: Pipeline.Result
        let continuesPrevious: Bool
    }

    init(pipeline: Pipeline, vad: VadManager) {
        self.pipeline = pipeline
        self.vad = vad
        (input, feed) = AsyncStream.makeStream(of: [Float].self)
        consumer = Task { await consume() }
    }

    /// Called for every captured chunk, in order (including the pre-roll first).
    func append(_ chunk: [Float]) {
        feed.yield(chunk)
    }

    /// Stops listening; segments already cut keep transcribing.
    func stop() async {
        feed.finish()
        await consumer?.value
    }

    /// Returns the full text: finished segments plus the tail of `recording`,
    /// which must be the same audio that was appended.
    func finish(_ recording: [Float]) async throws -> Outcome {
        await stop()
        let released = Date()
        let tail = Array(recording[min(segmentStart, recording.count)...])
        var pieces = try await pending?.value ?? []
        if !tail.isEmpty || pieces.isEmpty {
            pieces.append(try await Self.transcribe(tail.isEmpty ? recording : tail, after: pieces, with: pipeline))
        }
        return Outcome(text: Self.join(pieces), segments: pieces.map(\.result),
                       tailMs: Int(Date().timeIntervalSince(released) * 1000))
    }

    /// Waits for the segments cut so far (eval only: models the work finishing during speech).
    func settle() async {
        _ = try? await pending?.value
    }

    private func consume() async {
        var state = VadStreamState.initial()
        for await chunk in input {
            samples += chunk
            while (probabilities.count + 1) * Self.block <= samples.count {
                let start = probabilities.count * Self.block
                let result = try? await vad.processStreamingChunk(Array(samples[start..<start + Self.block]), state: state)
                if let result { state = result.state }
                probabilities.append(result?.probability ?? 1)
                cutIfReady()
            }
        }
    }

    private func cutIfReady() {
        let end = probabilities.count * Self.block
        let length = end - segmentStart
        guard length >= Self.minSegment else { return }

        // A pause: cut in its middle.
        var silent = 0
        while silent < probabilities.count && probabilities[probabilities.count - 1 - silent] < Self.silenceProbability {
            silent += 1
        }
        if silent >= Self.pauseBlocks {
            submit(upTo: end - silent * Self.block / 2)
        } else if length >= Self.maxSegment {
            // No pause for a long time: cut in the quietest block of the last few seconds.
            let first = max(segmentStart / Self.block + 1, probabilities.count - 24)
            let quietest = (first..<probabilities.count).min { probabilities[$0] < probabilities[$1] } ?? probabilities.count - 1
            submit(upTo: quietest * Self.block + Self.block / 2)
        }
    }

    private func submit(upTo cut: Int) {
        let segment = Array(samples[segmentStart..<cut])
        segmentStart = cut
        let previous = pending
        let pipeline = pipeline
        pending = Task {
            let done = try await previous?.value ?? []
            return done + [try await Self.transcribe(segment, after: done, with: pipeline)]
        }
    }

    private static func transcribe(_ audio: [Float], after done: [Piece], with pipeline: Pipeline) async throws -> Piece {
        let previous = done.last?.result.text
        let result = try await pipeline.transcribe(audio, context: previous)
        var continues = false
        if let previous, previous.hasSuffix("."), !result.text.isEmpty {
            continues = await pipeline.continues(previous, result.text)
        }
        return Piece(result: result, continuesPrevious: continues)
    }

    /// Joins pieces, rejoining sentences that were split at a pause.
    private static func join(_ pieces: [Piece]) -> String {
        var out = ""
        for piece in pieces where !piece.result.text.isEmpty {
            var next = piece.result.text
            if let last = out.last {
                if piece.continuesPrevious && last == "." {
                    out.removeLast()
                    next = lowercasingFirstWord(next)
                } else if !".?!".contains(last) {
                    next = lowercasingFirstWord(next)
                }
            }
            out += out.isEmpty ? next : " " + next
        }
        return out
    }

    /// "This is" → "this is", but leaves "I", "I'm", acronyms and the like alone.
    private static func lowercasingFirstWord(_ text: String) -> String {
        let word = text.prefix { $0.isLetter || $0 == "'" }
        guard !word.isEmpty, word != "I", !word.hasPrefix("I'"), word.dropFirst().allSatisfy(\.isLowercase) else { return text }
        return text.prefix(1).lowercased() + text.dropFirst()
    }
}
