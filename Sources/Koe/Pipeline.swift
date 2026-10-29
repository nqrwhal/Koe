import Foundation

/// Bark (Neural Engine) and Qwen3-ASR (GPU) transcribe in parallel. When they agree (ignoring the
/// fillers and repeats Bark drops, see ``Disagreements``), Qwen's cleaned text is used as is;
/// otherwise Gemma fuses each sentence where they differ.
/// Qwen and Gemma load in the background; until they're ready, Bark's text is used alone.
final class Pipeline {
    struct Result {
        let text: String
        let route: String  // "bark-only", "agree", "fuse", "qwen-fallback"
        let choices: Int
        let barkMs: Int
        let qwenMs: Int
        let fuseMs: Int
    }

    private let bark = Transcriber()
    private let qwen = QwenTranscriber()
    private let fuser = Fuser()
    private let terms = Vocabulary.load()

    func loadBark(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await bark.load(progress: progress)
    }

    /// Loads Qwen, then Gemma. Failures are logged and leave the pipeline on the previous tier.
    func loadRest(status: @escaping (String) -> Void) async {
        do {
            status("Loading Qwen…")
            try await qwen.load()
            status("Loading Gemma…")
            try await fuser.load(terms: terms)
            status("Ready")
        } catch {
            log.error("model load failed: \(error, privacy: .public)")
            status("Some models failed to load")
        }
    }

    /// Runs each model once so the GPU and Neural Engine are awake before the next dictation.
    func warmUp() async {
        _ = try? await bark.transcribe([Float](repeating: 0, count: 16_000), sampleRate: 16_000)
        _ = await qwen.transcribe([Float](repeating: 0, count: 16_000), context: "")
        _ = await fuser.fuse("ok", "ok", draft: "ok")
    }

    /// Called on key press: a tiny Qwen run gets the GPU clocked up while the user is still talking.
    func wakeGPU() {
        Task { _ = await qwen.transcribe([Float](repeating: 0, count: 8_000), context: "") }
    }

    /// Expects 16 kHz mono samples.
    func transcribe(_ samples: [Float]) async throws -> Result {
        let context = terms.joined(separator: ", ")
        async let barkRun = timed { try await self.bark.transcribe(samples, sampleRate: 16_000) }
        async let qwenRun = timed { await self.qwen.transcribe(samples, context: context) }
        let (a, barkMs) = try await barkRun
        let (b, qwenMs) = await qwenRun

        guard let b, !b.isEmpty else {
            return Result(text: a, route: "bark-only", choices: 0, barkMs: barkMs, qwenMs: qwenMs, fuseMs: 0)
        }
        let disagreements = Disagreements(a: a, b: b, terms: terms)
        let count = disagreements.choiceCount
        let sentences = disagreements.sentences()
        if count == 0 {
            return Result(text: Disagreements.join(sentences.map(\.b)), route: "agree", choices: 0,
                          barkMs: barkMs, qwenMs: qwenMs, fuseMs: 0)
        }
        // Only sentences containing a choice go to Gemma, adjacent ones together;
        // the rest are Qwen's cleaned text.
        var parts: [String] = []
        var fuseMs = 0
        var fellBack = false
        var index = 0
        while index < sentences.count {
            guard sentences[index].disputed else { parts.append(sentences[index].b); index += 1; continue }
            var end = index
            while end < sentences.count && sentences[end].disputed { end += 1 }
            let group = sentences[index..<end]
            let a = group.map(\.a).joined(separator: " "), b = group.map(\.b).joined(separator: " ")
            let (fused, ms) = await timed { await self.fuser.fuse(a, b, draft: b) }
            fuseMs += ms
            if let fused, !fused.isEmpty { parts.append(fused) } else { parts.append(b); fellBack = true }
            index = end
        }
        return Result(text: Disagreements.join(parts), route: fellBack ? "qwen-fallback" : "fuse", choices: count,
                      barkMs: barkMs, qwenMs: qwenMs, fuseMs: fuseMs)
    }

    private func timed<T>(_ body: () async throws -> T) async rethrows -> (T, Int) {
        let start = Date()
        let value = try await body()
        return (value, Int(Date().timeIntervalSince(start) * 1000))
    }
}
