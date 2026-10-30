import FluidAudio
import Foundation
import HuggingFace

/// `Koe --install-models`: downloads and prepares every model up front, so the first launch after
/// installing is instant. It uses the same code as a normal launch, so the files land where Koe
/// looks for them. One line per event goes to stdout for install.sh to draw:
///
///     model <id> <bytes> <name…>   each model, before any download starts
///     progress <id> <0…1>          every 150 ms while a model downloads or compiles
///     done <id>
///     fail <id> <message…>
enum ModelInstaller {
    private struct Model {
        let id: String
        let bytes: Int
        let name: String
        /// Where the download lands. Some loaders only report progress when a whole file is done,
        /// so the bytes growing here keep the progress bar moving in between.
        let folders: [URL]
        let install: (Ticker) async throws -> Void
    }

    private static let hub = HubCache.default.cacheDirectory
    private static func huggingFace(_ repo: String) -> [URL] {
        [hub.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--")),
         hub.appendingPathComponent("mlx-audio/" + repo.replacingOccurrences(of: "/", with: "_"))]
    }

    static func run() async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        let models = [
            Model(id: "bark", bytes: 427_000_000, name: "Parakeet speech model", folders: [fluidAudio("bark-3.0-clean")]) {
                ticker in try await Transcriber().load(progress: { ticker.update($0) })
            },
            Model(id: "vad", bytes: 1_000_000, name: "Pause detection", folders: [fluidAudio("silero-vad")]) {
                ticker in _ = try await VadManager(progressHandler: { ticker.update($0.fractionCompleted) })
            },
            Model(id: "qwen", bytes: 684_000_000, name: "Qwen3-ASR speech model",
                  folders: huggingFace("mlx-community/Qwen3-ASR-0.6B-4bit")) {
                ticker in try await QwenTranscriber.download(progress: { ticker.update($0) })
            },
            Model(id: "gemma", bytes: 4_800_000_000, name: "Gemma 4 language model",
                  folders: huggingFace("mlx-community/gemma-4-e4b-it-4bit")) {
                ticker in try await Fuser.download(progress: { ticker.update($0) })
            },
        ]
        for model in models { print("model \(model.id) \(model.bytes) \(model.name)") }

        var failed = false
        for model in models {
            let ticker = Ticker(id: model.id, bytes: model.bytes, folders: model.folders)
            do {
                try await model.install(ticker)
                ticker.stop()
                print("done \(model.id)")
            } catch {
                ticker.stop()
                print("fail \(model.id) \(error.localizedDescription)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    private static func fluidAudio(_ name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/\(name)")
    }

    /// Prints one model's latest progress every 150 ms, also while it compiles and reports nothing,
    /// so the installer's spinner keeps moving. Progress is whichever is further along: what the
    /// loader reported, or the bytes in the model's folders (held below 100% until it's ready).
    final class Ticker: @unchecked Sendable {
        private let id: String
        private let bytes: Int
        private let folders: [URL]
        private let lock = NSLock()
        private var fraction = 0.0
        private let timer = DispatchSource.makeTimerSource(queue: .global())

        init(id: String, bytes: Int, folders: [URL]) {
            self.id = id
            self.bytes = bytes
            self.folders = folders
            timer.schedule(deadline: .now(), repeating: .milliseconds(150))
            timer.setEventHandler { [weak self] in self?.emit() }
            timer.resume()
        }

        func update(_ value: Double) {
            lock.withLock { fraction = max(fraction, min(value, 1)) }
        }


        func stop() {
            timer.cancel()
        }

        private func emit() {
            let onDisk = min(Double(bytesOnDisk()) / Double(bytes), 0.99)
            let value = lock.withLock { fraction = max(fraction, onDisk); return fraction }
            print("progress \(id) \(String(format: "%.4f", value))")
        }

        private func bytesOnDisk() -> Int {
            folders.reduce(0) { total, folder in
                let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])
                return total + (files?.reduce(0) { sum, item in
                    guard let url = item as? URL,
                          let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                          values.isSymbolicLink != true else { return sum }
                    return sum + (values.fileSize ?? 0)
                } ?? 0)
            }
        }
    }
}
