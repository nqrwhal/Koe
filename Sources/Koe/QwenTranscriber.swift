import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT

/// Qwen3-ASR 0.6B on the GPU via MLX. It runs alongside Bark, which uses the Neural Engine,
/// so the second opinion costs little extra wall time.
///
/// It gets no vocabulary hints: on real recordings, hint lists made it bend words toward
/// listed terms ("Codex" → "Koe, Dex") and sometimes print the list instead of transcribing.
/// Gemma applies the vocabulary instead (see ``Fuser``).
actor QwenTranscriber {
    private static let repo = "mlx-community/Qwen3-ASR-0.6B-4bit"
    private var model: Qwen3ASRModel?

    /// Downloads the model into the cache `load()` reads from, reporting progress (for the installer).
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let client = HubClient(cache: .default)
        let directory = try await ModelUtils.resolveOrDownloadModel(
            client: client, cache: client.cache ?? .default, repoID: Repo.ID(rawValue: repo)!,
            requiredExtension: "safetensors", progressHandler: { progress($0.fractionCompleted) })
        _ = try await Qwen3ASRModel.fromModelDirectory(directory)
    }

    func load() async throws {
        let model = try await Qwen3ASRModel.fromPretrained(Self.repo)
        _ = model.generate(audio: MLXArray.zeros([16_000]), language: "English")
        self.model = model
    }

    /// Nil until the model has loaded. Expects 16 kHz mono samples.
    func transcribe(_ samples: [Float]) -> String? {
        guard let model else { return nil }
        return model.generate(audio: MLXArray(samples), language: "English")
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
