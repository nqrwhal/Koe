import MLX
import MLXAudioSTT

/// Qwen3-ASR 0.6B on the GPU via MLX. It runs alongside Bark, which uses the Neural Engine,
/// so the second opinion costs little extra wall time.
actor QwenTranscriber {
    private var model: Qwen3ASRModel?

    func load() async throws {
        let model = try await Qwen3ASRModel.fromPretrained("mlx-community/Qwen3-ASR-0.6B-4bit")
        _ = model.generate(audio: MLXArray.zeros([16_000]), language: "English")
        self.model = model
    }

    /// Nil until the model has loaded. Expects 16 kHz mono samples.
    func transcribe(_ samples: [Float], context: String) -> String? {
        guard let model else { return nil }
        return model.generate(audio: MLXArray(samples), context: context, language: "English")
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
