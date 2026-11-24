import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT

/// Qwen3-ASR 0.6B on the GPU via MLX. It runs alongside the Neural Engine recognizer,
/// so the second opinion costs little extra wall time.
actor QwenTranscriber {
    private static let repo = "mlx-community/Qwen3-ASR-0.6B-4bit"
    private var model: Qwen3ASRModel?

    var isLoaded: Bool { model != nil }

    private static func loadFromHub(progress: (@Sendable (Double) -> Void)?) async throws -> Qwen3ASRModel {
        let client = HubClient(cache: .default)
        let directory = try await ModelUtils.resolveOrDownloadModel(
            client: client,
            cache: client.cache ?? .default,
            repoID: Repo.ID(rawValue: repo)!,
            requiredExtension: "safetensors",
            progressHandler: { p in progress?(p.fractionCompleted) }
        )
        return try await Qwen3ASRModel.fromModelDirectory(directory)
    }

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await loadFromHub(progress: progress)
    }

    func load(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if model != nil { return }
        MLX.Memory.cacheLimit = Fuser.defaultCacheLimitBytes
        let loaded = try await Self.loadFromHub(progress: progress)
        _ = loaded.generate(audio: MLXArray.zeros([16_000]), language: "English")
        self.model = loaded
        MLX.Memory.clearCache()
    }

    func unload() {
        model = nil
        MLX.Memory.clearCache()
    }

    /// Nil until loaded, or when output loops into the token cap. Expects 16 kHz mono samples.
    func transcribe(_ samples: [Float]) -> String? {
        guard let model else { return nil }
        let maxTokens = 32 + samples.count * 12 / 16_000
        let output = model.generate(audio: MLXArray(samples), maxTokens: maxTokens, language: "English")
        guard output.generationTokens < maxTokens else { return nil }
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
