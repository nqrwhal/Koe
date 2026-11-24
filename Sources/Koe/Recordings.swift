import AVFoundation

/// When enabled, keeps each dictation's audio and transcript locally for tuning and History playback.
enum Recordings {
    static let defaultsKey = "saveRecordings"
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Koe/Recordings")

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    @discardableResult
    static func save(_ samples: [Float], sampleRate: Double, transcript: String) -> String? {
        guard enabled, !samples.isEmpty else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let wavName = name + ".wav"
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            let file = try AVAudioFile(forWriting: folder.appendingPathComponent(wavName), settings: format.settings)
            try file.write(from: buffer)
            try transcript.write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
            return wavName
        } catch {
            log.error("saving recording failed: \(error, privacy: .public)")
            return nil
        }
    }
}
