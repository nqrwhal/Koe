import AppKit
import AVFoundation

// koe --eval file.wav… : run the live pipeline on 16 kHz recordings and print JSON lines (ms = after release).
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
        // Simulate a live dictation: feed the audio in capture-sized chunks, let segments cut during
        // "speech" finish (they would, being faster than real time), then time only the tail.
        let live = pipeline.startLive()!
        for start in stride(from: 0, to: samples.count, by: 160) {
            live.append(Array(samples[start..<min(start + 160, samples.count)]))
        }
        await live.stop()
        await live.settle()
        let outcome = try await live.finish(samples)
        let last = outcome.segments.last!
        let row: [String: Any] = [
            "file": URL(fileURLWithPath: path).lastPathComponent, "text": outcome.text, "segments": outcome.segments.count,
            "ms": outcome.tailMs, "route": last.route, "qwen_ms": last.qwenMs, "fuse_ms": last.fuseMs,
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
