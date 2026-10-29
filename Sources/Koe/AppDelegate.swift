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

    /// Taps shorter than this are treated as accidental.
    private let minimumHold: TimeInterval = 0.25
    /// Keep listening briefly after release so the last word isn't clipped.
    private let tail: TimeInterval = 0.05

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        setIcon("ellipsis")

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
        do {
            try recorder.start()
        } catch {
            setStatus("Microphone unavailable")
            return
        }
        recording = true
        pressedAt = Date()
        pipeline.wakeGPU()
        setIcon("waveform.circle.fill")
        hud.show(.listening)
    }

    private func finishRecording() {
        guard recording else { return }
        if Date().timeIntervalSince(pressedAt) < minimumHold { return cancelRecording() }
        hud.show(.transcribing)

        DispatchQueue.main.asyncAfter(deadline: .now() + tail) { [self] in
            let samples = recorder.stop()
            let rate = recorder.sampleRate
            recording = false
            setIcon(ready ? "waveform" : "ellipsis")
            let released = Date()

            Task { @MainActor in
                do {
                    try await modelLoad?.value
                    let result = try await pipeline.transcribe(samples)
                    let text = result.text
                    Recordings.save(samples, sampleRate: rate, transcript: text)
                    hud.hide()
                    guard !text.isEmpty else { return }
                    Paster.paste(text + " ")
                    remember(text)
                    let audioSeconds = Double(samples.count) / rate
                    let pasteMs = Int(Date().timeIntervalSince(released) * 1000)
                    log.info("\(audioSeconds, format: .fixed(precision: 1), privacy: .public)s audio → \(pasteMs, privacy: .public)ms to paste via \(result.route, privacy: .public) [\(result.choices, privacy: .public) choices] (bark \(result.barkMs, privacy: .public)ms, qwen \(result.qwenMs, privacy: .public)ms, fuse \(result.fuseMs, privacy: .public)ms)")
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
        recording = false
        setIcon(ready ? "waveform" : "ellipsis")
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
            if !recording { setIcon("waveform") }
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

    private func setIcon(_ symbol: String) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Koe")
    }
}
