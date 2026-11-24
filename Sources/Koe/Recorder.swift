import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
#if os(iOS)
import AVFAudio
import UIKit
#endif

/// Captures 16 kHz mono audio from the configured or default input with an AudioQueue.
/// After each dictation the mic can stay warm for a configurable duration with a short rolling
/// buffer, so speech that starts right at (or just before) the key press is kept.
final class Recorder {
    #if os(macOS)
    struct AudioInputDevice: Identifiable, Hashable, Sendable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    static func availableInputDevices() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceIDs) == noErr else {
            return []
        }

        var result: [AudioInputDevice] = []
        for id in deviceIDs {
            guard hasInputChannels(id),
                  let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, selector: kAudioObjectPropertyName)
            else { continue }
            result.append(AudioInputDevice(id: id, uid: uid, name: name))
        }
        return result
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr else {
            return false
        }
        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }
    #endif

    var onLevel: (Float) -> Void = { _ in }
    /// Receives the pre-roll and then every captured chunk, in order, while recording.
    var onCapture: ([Float]) -> Void = { _ in }
    let sampleRate: Double = 16_000

    var selectedDeviceUID: String? {
        didSet {
            if oldValue != selectedDeviceUID && queue != nil && !capturing {
                stopQueue()
            }
        }
    }
    var warmFor: TimeInterval = 180 {
        didSet {
            if warmFor <= 0 && queue != nil && !capturing {
                stopQueue()
            }
        }
    }

    private let preRollSeconds = 0.3

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
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.stopQueue() }
        #else
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            guard let self, self.queue != nil, self.selectedDeviceUID == nil else { return }
            self.stopQueue()
            try? self.startQueue()
        }
        #endif
    }

    func start() throws {
        coolDown?.cancel()
        let warm = queue != nil
        lock.withLock {
            samples = warm ? Array(ring.suffix(Int(preRollSeconds * sampleRate))) : []
            onCapture(samples)
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
        if warmFor <= 0 {
            stopQueue()
        } else {
            let item = DispatchWorkItem { [weak self] in self?.stopQueue() }
            coolDown = item
            DispatchQueue.main.asyncAfter(deadline: .now() + warmFor, execute: item)
        }
        return captured
    }

    private func startQueue() throws {
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.record)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
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

        #if os(macOS)
        if let uid = selectedDeviceUID, Self.availableInputDevices().contains(where: { $0.uid == uid }) {
            var cfUID = uid as CFString
            let err = AudioQueueSetProperty(
                newQueue,
                kAudioQueueProperty_CurrentDevice,
                &cfUID,
                UInt32(MemoryLayout<CFString>.size)
            )
            if err != noErr {
                log.error("Failed to bind microphone UID \(uid, privacy: .public): OSStatus \(err, privacy: .public)")
            }
        }
        #endif

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
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
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
                onCapture(Array(chunk))
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
