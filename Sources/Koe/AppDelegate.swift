import AppKit
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let lastItem = NSMenuItem(title: "Nothing dictated yet", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let recordingsItem = NSMenuItem(title: "Save Recordings for Tuning", action: #selector(toggleRecordings), keyEquivalent: "")

    private let hotkey = Hotkey()
    private let recorder = Recorder()
    private let pipeline = Pipeline()
    private let hud = HUD()

    private var ready = false
    private var modelLoad: Task<Void, Error>?
    private var recording = false
    private var pressedAt = Date()
    private var lastText: String?
    private var live: LiveTranscription?

    /// Taps shorter than this are treated as accidental.
    private let minimumHold: TimeInterval = 0.25
    /// Keep listening briefly after release so the last word isn't clipped.
    private let tail: TimeInterval = 0.05

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        setIcon(.loading)

        hotkey.onPress = { [unowned self] in startRecording() }
        hotkey.onRelease = { [unowned self] in finishRecording() }
        hotkey.onCancel = { [unowned self] in cancelRecording() }
        recorder.onLevel = { [unowned self] in hud.model.level = $0 }

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        installHotkeyWhenTrusted()
        loadModel()

        // Bring the GPU and Neural Engine back up after sleep, before the next key press.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [unowned self] _ in
            Task { await pipeline.warmUp() }
        }
    }

    // MARK: Dictation

    private func startRecording() {
        // Record even while the model is still loading; transcription waits for it.
        guard !recording else { return }
        let session = pipeline.startLive()
        live = session
        recorder.onCapture = { session?.append($0) }
        do {
            try recorder.start()
        } catch {
            setStatus("Microphone unavailable")
            return
        }
        recording = true
        pressedAt = Date()
        pipeline.wakeGPU()
        setIcon(.recording)
        hud.show(.listening)
    }

    private func finishRecording() {
        guard recording else { return }
        if Date().timeIntervalSince(pressedAt) < minimumHold { return cancelRecording() }
        hud.show(.transcribing)

        DispatchQueue.main.asyncAfter(deadline: .now() + tail) { [self] in
            let samples = recorder.stop()
            let rate = recorder.sampleRate
            let session = live
            live = nil
            recording = false
            setIcon(ready ? .idle : .loading)
            let released = Date()

            Task { @MainActor in
                do {
                    try await modelLoad?.value
                    let text: String
                    let summary: String
                    if let session {
                        let outcome = try await session.finish(samples)
                        text = outcome.text
                        let last = outcome.segments.last
                        summary = "\(outcome.segments.count) segments, tail \(outcome.tailMs)ms"
                            + (last.map { ", last via \($0.route) (qwen \($0.qwenMs)ms, fuse \($0.fuseMs)ms)" } ?? "")
                    } else {
                        let r = try await pipeline.transcribe(samples)
                        text = r.text
                        summary = "whole via \(r.route) (qwen \(r.qwenMs)ms, fuse \(r.fuseMs)ms)"
                    }
                    Recordings.save(samples, sampleRate: rate, transcript: text)
                    hud.hide()
                    guard !text.isEmpty else { return }
                    Paster.paste(text + " ")
                    remember(text)
                    let audioSeconds = Double(samples.count) / rate
                    let pasteMs = Int(Date().timeIntervalSince(released) * 1000)
                    log.info("\(audioSeconds, format: .fixed(precision: 1), privacy: .public)s audio → \(pasteMs, privacy: .public)ms to paste; \(summary, privacy: .public)")
                } catch {
                    hud.hide()
                    log.error("transcription failed: \(error, privacy: .public)")
                }
            }
        }
    }

    private func cancelRecording() {
        guard recording else { return }
        _ = recorder.stop()
        let session = live
        live = nil
        Task { await session?.stop() }
        recording = false
        setIcon(ready ? .idle : .loading)
        hud.hide()
    }

    // MARK: Setup

    private func loadModel() {
        setStatus("Downloading speech model…")
        let load = Task { @MainActor in
            try await pipeline.loadBark { fraction in
                DispatchQueue.main.async { self.setStatus("Downloading speech model… \(Int(fraction * 100))%") }
            }
            ready = true
            if !recording { setIcon(.idle) }
            setStatus("Hold Right ⌘ to dictate")
            await pipeline.loadRest { status in
                self.setStatus(status == "Ready" ? "Hold Right ⌘ to dictate" : "Hold Right ⌘ to dictate (\(status))")
            }
        }
        modelLoad = load
        Task { @MainActor in
            if case .failure(let error) = await load.result {
                setStatus("Model failed to load")
                log.error("model load failed: \(error, privacy: .public)")
            }
        }
    }

    private func installHotkeyWhenTrusted() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary), hotkey.install() { return }
        setStatus("Grant Accessibility access in System Settings")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [unowned self] timer in
            guard AXIsProcessTrusted(), hotkey.install() else { return }
            timer.invalidate()
            setStatus(ready ? "Hold Right ⌘ to dictate" : "Downloading speech model…")
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        statusLine.isEnabled = false
        lastItem.target = self
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(lastItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        recordingsItem.target = self
        recordingsItem.state = Recordings.enabled ? .on : .off
        menu.addItem(recordingsItem)
        menu.addItem(NSMenuItem(title: "Quit Koe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func remember(_ text: String) {
        lastText = text
        let preview = text.count > 50 ? text.prefix(50) + "…" : text
        lastItem.title = "Copy last: \(preview)"
        lastItem.action = #selector(copyLast)
    }

    @objc private func copyLast() {
        guard let lastText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log.error("login item change failed: \(error, privacy: .public)")
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleRecordings() {
        Recordings.enabled.toggle()
        recordingsItem.state = Recordings.enabled ? .on : .off
    }

    private func setStatus(_ text: String) {
        statusLine.title = text
    }

    private enum IconState { case loading, idle, recording }

    /// The menu bar shows 声: dimmed while models load, red while recording.
    private func setIcon(_ state: IconState) {
        let color: NSColor = switch state {
        case .loading: .tertiaryLabelColor
        case .idle: .labelColor
        case .recording: .systemRed
        }
        statusItem.button?.attributedTitle = NSAttributedString(string: "声", attributes: [
            .font: NSFont(name: "HiraMinProN-W6", size: 15) ?? .menuBarFont(ofSize: 15),
            .foregroundColor: color,
        ])
        statusItem.button?.setAccessibilityLabel("Koe")
    }
}
