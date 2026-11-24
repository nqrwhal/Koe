import FluidAudio
import Foundation
import HuggingFace

/// `Koe --install-models`: downloads and prepares default models up front so the first launch is fast.
enum ModelInstaller {
    private struct Model {
        let id: String
        let bytes: Int
        let name: String
        let folders: [URL]
        let install: (Ticker) async throws -> Void
    }

    private static let hub = HubCache.default.cacheDirectory
    private static func huggingFace(_ repo: String) -> [URL] {
        [hub.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--")),
         hub.appendingPathComponent("mlx-audio/" + repo.replacingOccurrences(of: "/", with: "_"))]
    }

    static func run(fuser: FuserModel = .qwen3_1_7b, includeGPU: Bool = true) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        var models = [
            Model(id: "parakeet", bytes: 610_000_000, name: "Parakeet Unified 0.6B",
                  folders: [fluidAudio("parakeet-unified-en-0.6b")]) { ticker in
                try await Transcriber().load(backend: .parakeetUnifiedStreaming) { ticker.update($0) }
            },
            Model(id: "vad", bytes: 1_000_000, name: "Pause detection", folders: [fluidAudio("silero-vad")]) { ticker in
                _ = try await VadManager(progressHandler: { ticker.update($0.fractionCompleted) })
            },
            Model(id: "ctc", bytes: 106_000_000, name: "Vocabulary spotting",
                  folders: [fluidAudio("parakeet-ctc-110m-coreml")]) { ticker in
                _ = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                ticker.update(1.0)
            },
        ]

        if includeGPU {
            models.append(
                Model(id: "qwen", bytes: 684_000_000, name: "Qwen3-ASR speech model",
                      folders: huggingFace("mlx-community/Qwen3-ASR-0.6B-4bit")) { ticker in
                    try await QwenTranscriber.download { ticker.update($0) }
                }
            )
            models.append(
                Model(id: "fuser", bytes: fuser.downloadBytes, name: fuser.displayName,
                      folders: huggingFace(fuser.repoID)) { ticker in
                    try await Fuser.download(fuser) { ticker.update($0) }
                }
            )
        }

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
