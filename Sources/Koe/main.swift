import AppKit
import AVFoundation

// koe --eval file.wav… : run the full pipeline on 16 kHz recordings and print JSON lines.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--eval" {
    let pipeline = Pipeline()
    try await pipeline.loadBark { _ in }
    await pipeline.loadRest { FileHandle.standardError.write("\($0)\n".data(using: .utf8)!) }
    for path in CommandLine.arguments.dropFirst(2) {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        precondition(file.processingFormat.sampleRate == 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let r = try await pipeline.transcribe(samples)
        let row: [String: Any] = [
            "file": URL(fileURLWithPath: path).lastPathComponent, "text": r.text, "route": r.route, "choices": r.choices,
            "ms": max(r.barkMs, r.qwenMs) + r.fuseMs, "bark_ms": r.barkMs, "qwen_ms": r.qwenMs, "fuse_ms": r.fuseMs,
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: row), encoding: .utf8)!)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
