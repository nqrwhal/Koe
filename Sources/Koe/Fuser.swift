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
    private var stopTokens: Set<Int> = []
    private var canTrim = false

    func load(terms: [String]) async throws {
        let context = try await LLMModelFactory.shared.load(
            from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: "mlx-community/gemma-4-e4b-it-4bit"))
        let tokenizer = context.tokenizer
        stopTokens = Set([tokenizer.eosTokenId, tokenizer.convertTokenToId("<turn|>")].compactMap { $0 })

        let instructions = """
            Two different speech recognizers transcribed the same dictation by a software engineer.
            Write the single most likely correct transcript. Where they disagree, pick the reading that makes sense; \
            where both are wrong about a technical term, fix its spelling and casing (e.g. "J W T" -> "JWT", "cube cuddle" -> "kubectl").
            Never add content that neither transcript supports. Keep punctuation.
            Vocabulary — whenever the speaker plausibly said one of these, use exactly this spelling, \
            even if both transcripts spell it differently (e.g. "whisper flow" -> "Wispr Flow"): \(terms.joined(separator: ", "))
            Reply with only the transcript.


            """
        let prefix = tokenizer.encode(text: "<bos><|turn>user\n" + instructions, addSpecialTokens: false)
        let cache = try context.model.newCache(parameters: nil)
        eval(context.model(MLXArray(prefix.map(Int32.init)).reshaped([1, prefix.count]), cache: cache))
        prefixCache = cache
        canTrim = cache.allSatisfy(\.isTrimmable)
        self.context = context
        _ = fuse("ok", "ok", draft: "ok")  // compile kernels before the first real request
    }

    /// Nil until the model has loaded. `draft` is the text the answer most likely resembles.
    func fuse(_ a: String, _ b: String, draft: String) -> String? {
        guard let context else { return nil }
        let tokenizer = context.tokenizer
        let prompt = tokenizer.encode(text: "A: \(a)\nB: \(b)<turn|>\n<|turn>model\n", addSpecialTokens: false)
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
