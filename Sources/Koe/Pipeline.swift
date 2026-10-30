import FluidAudio
import Foundation

/// Bark (Neural Engine) and Qwen3-ASR (GPU) transcribe in parallel, and both transcripts get the
/// same free spelling fixes (``Speller``). When they agree (ignoring the fillers and repeats Bark
/// drops, see ``Disagreements``), Qwen's cleaned text is used as is; that's the fast path most
/// everyday speech takes. Otherwise Gemma settles only the sentences where they differ.
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
    private let personal: [String]  // the user's own terms, checked even when both recognizers agree
    private let terms: [String]  // the user's terms first, then the built-in list
    private let speller: Speller
    private var vad: VadManager?

    /// Create on the main thread (``Speller`` consults the system spell checker).
    init() {
        let personal = Vocabulary.loadPersonal()
        var seen = Set<String>()
        let terms = (personal + Vocabulary.builtIn).filter { seen.insert($0.lowercased()).inserted }
        self.personal = personal
        self.terms = terms
        speller = Speller(terms: terms)
    }

    func loadBark(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await bark.load(progress: progress)
        vad = try? await VadManager()
    }

    /// A session that transcribes while the key is held; nil until the VAD has loaded.
    func startLive() -> LiveTranscription? {
        vad.map { LiveTranscription(pipeline: self, vad: $0) }
    }

    /// Loads Qwen, then Gemma. Failures are logged and leave the pipeline on the previous tier.
    func loadRest(status: @escaping (String) -> Void) async {
        do {
            status("Loading Qwen…")
            try await qwen.load()
            status("Loading Gemma…")
            try await fuser.load()
            status("Ready")
        } catch {
            log.error("model load failed: \(error, privacy: .public)")
            status("Some models failed to load")
        }
    }

    /// Runs each model once so the GPU and Neural Engine are awake before the next dictation.
    func warmUp() async {
        _ = try? await bark.transcribe([Float](repeating: 0, count: 16_000), sampleRate: 16_000)
        _ = await qwen.transcribe([Float](repeating: 0, count: 16_000))
        _ = await fuser.fuse("ok", "ok", draft: "ok", context: nil, vocabulary: [])
    }

    /// Called on key press: a tiny Qwen run gets the GPU clocked up while the user is still talking.
    func wakeGPU() {
        Task { _ = await qwen.transcribe([Float](repeating: 0, count: 8_000)) }
    }

    /// Whether `next` continues the sentence that `previous` (split off at a pause) ended with a period.
    /// False until Gemma has loaded.
    func continues(_ previous: String, _ next: String) async -> Bool {
        await fuser.continues(previous, next) ?? false
    }

    /// Expects 16 kHz mono samples. `context` is the final text preceding this piece, if any.
    func transcribe(_ samples: [Float], context preceding: String? = nil) async throws -> Result {
        async let barkRun = timed { try await self.bark.transcribe(samples, sampleRate: 16_000) }
        async let qwenRun = timed { await self.qwen.transcribe(samples) }
        let (rawA, barkMs) = try await barkRun
        let (rawB, qwenMs) = await qwenRun
        let a = speller.normalize(rawA)

        guard let rawB, !rawB.isEmpty else {
            return Result(text: a, route: "bark-only", choices: 0, barkMs: barkMs, qwenMs: qwenMs, fuseMs: 0)
        }
        let b = speller.normalize(rawB)
        let disagreements = Disagreements(a: a, b: b, terms: personal)
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
            let previous = parts.last ?? preceding
            let vocabulary = Vocabulary.relevant(to: group.map(\.disputedText), personal: personal, builtIn: Vocabulary.builtIn)
            let (fused, ms) = await timed {
                await self.fuser.fuse(a, b, draft: b, context: previous, vocabulary: vocabulary)
            }
            fuseMs += ms
            if let fused, !fused.isEmpty {
                parts.append(Disagreements.merge(fused, into: group))
            } else {
                parts.append(b)
                fellBack = true
            }
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
