import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// Captures 16 kHz mono audio from the default input with an AudioQueue.
/// After each dictation the mic stays warm for a few minutes, keeping a short rolling
/// buffer, so speech that starts right at (or just before) the key press is kept.
/// Cold starts cost whatever the device needs (~70 ms for a C920, ~470 ms for a Studio Display).
final class Recorder {
    var onLevel: (Float) -> Void = { _ in }
    let sampleRate: Double = 16_000

    private let preRollSeconds = 0.3
    private let warmFor: TimeInterval = 180

    private let callbackQueue = DispatchQueue(label: "koe.recorder")
    private var queue: AudioQueueRef?
    private var coolDown: DispatchWorkItem?

    // Guarded by `lock`; written from the audio callback.
    private let lock = NSLock()
    private var capturing = false
    private var samples: [Float] = []
    private var ring: [Float] = []
    private var startedAt = Date()
    private var firstBufferLogged = false

    struct NoMicrophone: Error {}

    init() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            guard let self, queue != nil else { return }
            stopQueue()
            try? startQueue()
        }
    }

    func start() throws {
        coolDown?.cancel()
        let warm = queue != nil
        lock.withLock {
            samples = warm ? Array(ring.suffix(Int(preRollSeconds * sampleRate))) : []
            startedAt = Date()
            firstBufferLogged = warm
            capturing = true
        }
        if warm {
            log.info("warm start, \(Int(self.preRollSeconds * 1000), privacy: .public)ms pre-roll")
        } else {
            try startQueue()
        }
    }

    func stop() -> [Float] {
        let captured = lock.withLock {
            capturing = false
            ring.removeAll(keepingCapacity: true)
            return samples
        }
        let item = DispatchWorkItem { [weak self] in self?.stopQueue() }
        coolDown = item
        DispatchQueue.main.asyncAfter(deadline: .now() + warmFor, execute: item)
        return captured
    }

    private func startQueue() throws {
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var newQueue: AudioQueueRef?
        let status = AudioQueueNewInputWithDispatchQueue(&newQueue, &format, 0, callbackQueue) { [weak self] aq, buffer, _, _, _ in
            let count = Int(buffer.pointee.mAudioDataByteSize) / 4
            self?.receive(UnsafeBufferPointer(start: buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self), count: count))
            AudioQueueEnqueueBuffer(aq, buffer, 0, nil)
        }
        guard status == noErr, let newQueue else { throw NoMicrophone() }
        for _ in 0..<8 {
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(newQueue, 160 * 4, &buffer)  // 10 ms each
            if let buffer { AudioQueueEnqueueBuffer(newQueue, buffer, 0, nil) }
        }
        guard AudioQueueStart(newQueue, nil) == noErr else {
            AudioQueueDispose(newQueue, true)
            throw NoMicrophone()
        }
        queue = newQueue
    }

    private func stopQueue() {
        guard let queue else { return }
        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)
        self.queue = nil
    }

    private func receive(_ chunk: UnsafeBufferPointer<Float>) {
        let isCapturing = lock.withLock {
            if capturing {
                if !firstBufferLogged {
                    firstBufferLogged = true
                    let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
                    log.info("first audio \(ms, privacy: .public)ms after press")
                }
                samples.append(contentsOf: chunk)
            } else {
                ring.append(contentsOf: chunk)
                let limit = Int(preRollSeconds * sampleRate)
                if ring.count > limit * 2 { ring.removeFirst(ring.count - limit) }
            }
            return capturing
        }
        guard isCapturing, let base = chunk.baseAddress else { return }
        var rms: Float = 0
        vDSP_rmsqv(base, 1, &rms, vDSP_Length(chunk.count))
        let db = 20 * log10(max(rms, 1e-6))
        let level = min(max((db + 55) / 40, 0), 1)
        DispatchQueue.main.async { self.onLevel(level) }
    }
}
