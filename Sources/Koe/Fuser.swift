import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Gemma 4 E4B reconciles Bark's and Qwen's transcripts of the same audio into one.
///
/// Two speedups keep this around a few hundred milliseconds:
/// - the fixed instructions are prefilled once at load and their KV cache is copied per request;
/// - lookup decoding: the answer is usually Qwen's cleaned text with a few words changed, so
///   upcoming tokens are drafted from that text and verified in a single forward pass
///   (same result as plain greedy decoding).
actor Fuser {
    private var context: ModelContext?
    private var prefixCache: [KVCache] = []
    private var seamCache: [KVCache] = []
    private var yesTokens: [Int] = []
    private var noTokens: [Int] = []
    private let seamMargin: Float = 1  // calibrated on real seams: true continuations scored +1.4 and +6.3
    private var stopTokens: Set<Int> = []
    private var canTrim = false

    private static let configuration = ModelConfiguration(id: "mlx-community/gemma-4-e4b-it-4bit")

    /// Downloads the model into the cache `load()` reads from, reporting progress (for the installer).
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await LLMModelFactory.shared.load(
            from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration: configuration,
            progressHandler: { progress($0.fractionCompleted) })
    }

    func load() async throws {
        let context = try await LLMModelFactory.shared.load(
            from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration: Self.configuration)
        let tokenizer = context.tokenizer
        stopTokens = Set([tokenizer.eosTokenId, tokenizer.convertTokenToId("<turn|>")].compactMap { $0 })

        let instructions = """
            Two different speech recognizers transcribed the same dictation by a software engineer.
            Write the single most likely correct transcript. Where they disagree, pick the reading that makes sense; \
            where both are wrong about a technical term, fix its spelling and casing (e.g. "J W T" -> "JWT", "cube cuddle" -> "kubectl").
            Never add content that neither transcript supports. Keep punctuation.
            Vocabulary — whenever the speaker plausibly said one of the listed terms, use exactly its spelling, \
            even if both transcripts spell it differently (e.g. "whisper flow" -> "Wispr Flow"). \
            Don't use a term the transcripts don't sound like.
            Reply with only the transcript.


            """
        let prefix = tokenizer.encode(text: "<bos><|turn>user\n" + instructions, addSpecialTokens: false)
        let cache = try context.model.newCache(parameters: nil)
        eval(context.model(MLXArray(prefix.map(Int32.init)).reshaped([1, prefix.count]), cache: cache))
        prefixCache = cache
        canTrim = cache.allSatisfy(\.isTrimmable)

        let seamQuestion = """
            A dictation was split into two parts at a pause, and each part was transcribed separately, \
            so part 1 may end with a period that the speaker didn't intend.
            Does part 2 continue the same sentence as part 1? Answer yes or no.


            """
        yesTokens = ["yes", "Yes", "YES"].compactMap { tokenizer.convertTokenToId($0) }
        noTokens = ["no", "No", "NO"].compactMap { tokenizer.convertTokenToId($0) }
        let seamPrefix = tokenizer.encode(text: "<bos><|turn>user\n" + seamQuestion, addSpecialTokens: false)
        seamCache = try context.model.newCache(parameters: nil)
        eval(context.model(MLXArray(seamPrefix.map(Int32.init)).reshaped([1, seamPrefix.count]), cache: seamCache))
        self.context = context
        _ = fuse("ok", "ok", draft: "ok", context: nil, vocabulary: [])  // compile kernels before the first real request
    }

    /// Nil until the model has loaded. `draft` is the text the answer most likely resembles;
    /// `context` is the already-final text just before this piece of a longer dictation;
    /// `vocabulary` the terms that might appear in it (see ``Vocabulary/relevant(to:terms:limit:)``).
    func fuse(_ a: String, _ b: String, draft: String, context preceding: String?, vocabulary: [String]) -> String? {
        guard let context else { return nil }
        let tokenizer = context.tokenizer
        var lead = preceding.map { "Earlier in this dictation (context only): \($0)\n" } ?? ""
        if !vocabulary.isEmpty { lead += "Vocabulary: \(vocabulary.joined(separator: ", "))\n" }
        let prompt = tokenizer.encode(text: lead + "A: \(a)\nB: \(b)<turn|>\n<|turn>model\n", addSpecialTokens: false)
        let draftSource = canTrim ? tokenizer.encode(text: draft, addSpecialTokens: false) : []
        let cache = prefixCache.map { $0.copy() }

        var next = greedy(forward(prompt, cache)).last!
        var output: [Int] = []
        var position = 0
        while !stopTokens.contains(next) && output.count < prompt.count * 2 + 32 {
            output.append(next)
            let draft = lookup(output, in: draftSource, from: &position)
            let predictions = greedy(forward([next] + draft, cache))
            var accepted = 0
            while accepted < draft.count && draft[accepted] == predictions[accepted] { accepted += 1 }
            output += draft[..<accepted]
            if accepted < draft.count {
                for layer in cache { _ = layer.trim(draft.count - accepted) }
            }
            next = predictions[accepted]
        }
        return tokenizer.decode(tokenIds: output, skipSpecialTokens: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `next` continues the same sentence as `previous`; nil until the model has loaded.
    func continues(_ previous: String, _ next: String) -> Bool? {
        guard let context else { return nil }
        let end = previous.split(separator: " ").suffix(15).joined(separator: " ")
        let start = next.split(separator: " ").prefix(10).joined(separator: " ")
        let prompt = context.tokenizer.encode(
            text: "End of part 1: \"…\(end)\"\nStart of part 2: \"\(start)…\"<turn|>\n<|turn>model\n",
            addSpecialTokens: false)
        // Gemma leans towards "yes" when unsure, so require a clear margin over "no".
        let logits = forward(prompt, seamCache.map { $0.copy() })[0, -1]
        let yes = yesTokens.map { logits[$0].item(Float.self) }.max() ?? 0
        let no = noTokens.map { logits[$0].item(Float.self) }.max() ?? 0
        log.info("seam margin \(yes - no, privacy: .public): …\(end, privacy: .private) | \(start, privacy: .private)…")
        return yes - no > seamMargin
    }

    private func forward(_ tokens: [Int], _ cache: [KVCache]) -> MLXArray {
        context!.model(MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count]), cache: cache)
    }

    private func greedy(_ logits: MLXArray) -> [Int] {
        argMax(logits[0], axis: -1).asArray(Int32.self).map(Int.init)
    }

    /// The next source tokens after the latest stretch of output found in the source.
    private func lookup(_ output: [Int], in source: [Int], from position: inout Int) -> [Int] {
        for n in stride(from: 3, through: 1, by: -1) where output.count >= n && source.count >= n {
            let pattern = Array(output.suffix(n))
            var i = position
            while i + n <= source.count {
                if Array(source[i..<i + n]) == pattern {
                    position = i + 1
                    return Array(source[(i + n)..<min(i + n + 24, source.count)])
                }
                i += 1
            }
        }
        return []
    }
}
