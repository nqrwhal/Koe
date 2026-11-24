import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Small on-device LLM that reconciles base ANE and Qwen3-ASR transcripts of the same audio
/// only where they disagree, and resolves pause seams.
///
/// Two speedups keep this fast:
/// - the fixed instructions are prefilled once at load and their KV cache is copied per request;
/// - lookup decoding (when KV cache supports trimming): upcoming tokens are drafted from Qwen's
///   reading and verified in a single forward pass.
actor Fuser {
    private var context: ModelContext?
    private var activeModel: FuserModel?
    private var prefixCache: [KVCache] = []
    private var seamCache: [KVCache] = []
    private var yesTokens: [Int] = []
    private var noTokens: [Int] = []
    private var stopTokens: Set<Int> = []
    private var canTrim = false

    static let defaultCacheLimitBytes = 32 * 1024 * 1024

    var currentModel: FuserModel? { activeModel }
    var isLoaded: Bool { context != nil }

    static func download(_ model: FuserModel = .qwen3_1_7b, progress: @escaping @Sendable (Double) -> Void) async throws {
        let config = ModelConfiguration(id: model.repoID)
        _ = try await LLMModelFactory.shared.load(
            from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration: config,
            progressHandler: { progress($0.fractionCompleted) })
    }

    func load(_ model: FuserModel = .qwen3_1_7b, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if activeModel == model && context != nil { return }
        unload()

        MLX.Memory.cacheLimit = Self.defaultCacheLimitBytes
        let config = ModelConfiguration(id: model.repoID)
        let context = try await LLMModelFactory.shared.load(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: config,
            progressHandler: { p in progress?(p.fractionCompleted) }
        )
        let tokenizer = context.tokenizer

        let stopCandidates: [String] = switch model.family {
        case .gemma4: ["<turn|>", "<eos>"]
        case .qwen3, .qwen35: ["<|im_end|>", "<|endoftext|>"]
        }
        stopTokens = Set(([tokenizer.eosTokenId] + stopCandidates.map { tokenizer.convertTokenToId($0) }).compactMap { $0 })

        let instructions = """
            Two different speech recognizers transcribed the same dictation by a software engineer.
            Write the single most likely correct transcript. Where they disagree, pick the reading that makes sense; \
            where both are wrong about a technical term, fix its spelling and casing (e.g. "J W T" -> "JWT", "cube cuddle" -> "kubectl").
            Fix obvious intra-word punctuation glitches (e.g. "tuning,s" -> "tunings"). Never add content that neither transcript supports. Keep clean punctuation.
            Vocabulary — whenever the speaker plausibly said one of the listed terms, use exactly its spelling, \
            even if both transcripts spell it differently (e.g. "whisper flow" -> "Wispr Flow"). \
            Don't use a term the transcripts don't sound like.
            Reply with only the transcript.


            """

        let userTurnPrefix = switch model.family {
        case .gemma4: "<bos><|turn>user\n"
        case .qwen3, .qwen35: "<|im_start|>user\n"
        }

        let prefix = tokenizer.encode(text: userTurnPrefix + instructions, addSpecialTokens: false)
        let cache = try context.model.newCache(parameters: nil)
        eval(context.model(MLXArray(prefix.map(Int32.init)).reshaped([1, prefix.count]), cache: cache))
        prefixCache = cache
        canTrim = cache.allSatisfy(\.isTrimmable)

        let seamQuestion = """
            A dictation was split into two parts at a pause, and each part was transcribed separately, \
            so part 1 may end with a period that the speaker didn't intend.
            Does part 2 continue the same sentence as part 1? Answer yes or no.


            """

        yesTokens = Array(Set(
            ["yes", "Yes", "YES"].compactMap { tokenizer.convertTokenToId($0) }
            + ["yes", "Yes"].compactMap { tokenizer.encode(text: $0, addSpecialTokens: false).first }
        ))
        noTokens = Array(Set(
            ["no", "No", "NO"].compactMap { tokenizer.convertTokenToId($0) }
            + ["no", "No"].compactMap { tokenizer.encode(text: $0, addSpecialTokens: false).first }
        ))

        let seamPrefix = tokenizer.encode(text: userTurnPrefix + seamQuestion, addSpecialTokens: false)
        seamCache = try context.model.newCache(parameters: nil)
        eval(context.model(MLXArray(seamPrefix.map(Int32.init)).reshaped([1, seamPrefix.count]), cache: seamCache))

        self.context = context
        self.activeModel = model
        _ = fuse("ok", "ok", draft: "ok", context: nil, vocabulary: [])  // compile Metal kernels
        MLX.Memory.clearCache()
    }

    func unload() {
        context = nil
        activeModel = nil
        prefixCache = []
        seamCache = []
        yesTokens = []
        noTokens = []
        stopTokens = []
        canTrim = false
        MLX.Memory.clearCache()
    }

    private func replySuffix(for family: FuserModel.Family) -> String {
        switch family {
        case .gemma4:
            // Close Gemma 4's non-thinking reasoning channel so token 0 is the direct answer.
            return "<turn|>\n<|turn>model\n<|channel>thought\n<channel|>"
        case .qwen3, .qwen35:
            // Disable Qwen3 / Qwen3.5 thinking mode so fusion runs without <think> latency.
            return "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        }
    }

    /// Nil until the model has loaded.
    func fuse(_ a: String, _ b: String, draft: String, context preceding: String?, vocabulary: [String]) -> String? {
        guard let context, let activeModel else { return nil }
        let tokenizer = context.tokenizer
        var lead = preceding.map { "Earlier in this dictation (context only): \($0)\n" } ?? ""
        if !vocabulary.isEmpty { lead += "Vocabulary: \(vocabulary.joined(separator: ", "))\n" }
        let requestText = lead + "A: \(a)\nB: \(b)" + replySuffix(for: activeModel.family)
        let prompt = tokenizer.encode(text: requestText, addSpecialTokens: false)
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
        let decoded = tokenizer.decode(tokenIds: output, skipSpecialTokens: true)
        return TextCleaner.stripReasoningArtifacts(decoded)
    }

    /// Whether `next` continues the same sentence as `previous`; nil until the model has loaded.
    func continues(_ previous: String, _ next: String, relaxed: Bool = false) -> Bool? {
        guard let context, let activeModel else { return nil }
        let end = previous.split(whereSeparator: \.isWhitespace).suffix(15).joined(separator: " ")
        let start = next.split(whereSeparator: \.isWhitespace).prefix(10).joined(separator: " ")
        let promptText = "End of part 1: \"…\(end)\"\nStart of part 2: \"\(start)…\"" + replySuffix(for: activeModel.family)
        let prompt = context.tokenizer.encode(text: promptText, addSpecialTokens: false)
        let logits = forward(prompt, seamCache.map { $0.copy() })[0, -1]
        let yes = yesTokens.map { logits[$0].item(Float.self) }.max() ?? -Float.infinity
        let no = noTokens.map { logits[$0].item(Float.self) }.max() ?? -Float.infinity
        let margin = yes - no
        let threshold: Float = switch activeModel.family {
        case .gemma4: relaxed ? -0.5 : 0.5
        case .qwen3, .qwen35: relaxed ? -0.5 : 0.0
        }
        log.info("seam margin \(margin, privacy: .public) (threshold \(threshold, privacy: .public)): …\(end, privacy: .private) | \(start, privacy: .private)…")
        return margin > threshold
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
