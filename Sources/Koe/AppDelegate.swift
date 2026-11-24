import AppKit
import AVFoundation
import ServiceManagement

private final class CaptureRelay {
    private let lock = NSLock()
    private var buffer: [[Float]] = []
    private var session: LiveTranscription?
    private var cancelled = false

    func receive(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        let active: LiveTranscription? = lock.withLock {
            if cancelled { return nil }
            if let session { return session }
            buffer.append(chunk)
            return nil
        }
        active?.append(chunk)
    }

    func attach(_ session: LiveTranscription) {
        let buffered: [[Float]]? = lock.withLock {
            guard !cancelled else { return nil }
            self.session = session
            let out = buffer
            buffer.removeAll()
            return out
        }
        guard let buffered else {
            Task { await session.cancel() }
            return
        }
        for chunk in buffered {
            session.append(chunk)
        }
    }

    func currentSession() -> LiveTranscription? {
        lock.withLock { session }
    }

    func cancel() -> LiveTranscription? {
        lock.withLock {
            cancelled = true
            buffer.removeAll()
            let active = session
            session = nil
            return active
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let pasteLastItem = NSMenuItem(title: "Paste Last Dictation", action: #selector(pasteLast), keyEquivalent: "")
    private let recentMenu = NSMenu(title: "Recent Dictations")
    private let hybridModeItem = NSMenuItem(title: "Mode: Balanced Hybrid (~2.4 GB)", action: #selector(selectHybridMode), keyEquivalent: "")
    private let aneModeItem = NSMenuItem(title: "Mode: ANE Solo (~60 MB)", action: #selector(selectANEMode), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let recordingsItem = NSMenuItem(title: "Save Recordings for Tuning", action: #selector(toggleRecordings), keyEquivalent: "")

    private let settings = AppSettings.shared
    private let history = HistoryStore.shared
    private let hotkey = Hotkey()
    private let recorder = Recorder()
    private lazy var pipeline = Pipeline(options: settings.snapshot())
    private let hud = HUD()
    private var settingsWindow: SettingsWindowController?

    private var ready = false
    private var hotkeyTrusted = false
    private var isSyncingModels = false
    private var pendingModelSync = false
    private var activeSyncStatus: String?
    private var lastSyncError: String?
    private var modelLoad: Task<Void, Never>?
    private var recording = false
    private var captureRelay: CaptureRelay?
    private var startLiveTask: Task<Void, Never>?
    private var finishTailTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        buildMenu()
        setIcon(.loading)

        settingsWindow = SettingsWindowController(
            settings: settings,
            history: history,
            pipeline: pipeline,
            hotkey: hotkey,
            onPasteHistory: { [weak self] text in
                guard let self else { return }
                Paster.paste(text, spacing: self.settings.spacingMode)
            },
            onModelReloadRequested: { [weak self] in
                self?.scheduleModelSync()
            },
            onVocabularyChanged: { [weak self] in
                guard let self else { return }
                Task { await self.pipeline.reloadVocabularyIfNeeded(force: true) }
            }
        )

        syncHotkeySettings()
        syncRecorderSettings()
        settings.onHotkeyConfigChanged = { [weak self] in self?.syncHotkeySettings() }
        settings.onRecorderConfigChanged = { [weak self] in self?.syncRecorderSettings() }
        settings.onModelConfigChanged = { [weak self] in
            self?.refreshModeMenuChecks()
            self?.scheduleModelSync()
        }
        settings.onIdleTimerChanged = { [weak self] in
            guard let self else { return }
            self.pipeline.updateOptions(self.settings.snapshot())
            self.pipeline.syncIdleTimer()
        }

        hotkey.onPress = { [unowned self] in startRecording() }
        hotkey.onLock = { [unowned self] in
            if self.recording { self.hud.show(.lockedListening) }
        }
        hotkey.onRelease = { [unowned self] in finishRecording() }
        hotkey.onCancel = { [unowned self] in cancelRecording() }
        hotkey.onPasteLast = { [unowned self] in pasteLast() }

        recorder.onLevel = { [unowned self] level in
            Task { @MainActor in self.hud.model.level = level }
        }

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        installHotkeyWhenTrusted()
        scheduleModelSync()

        // Bring the GPU and Neural Engine back up after sleep, before the next key press.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [unowned self] _ in
            Task { await self.pipeline.warmUp() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            settingsWindow?.open(tab: .general)
        }
        return true
    }

    // MARK: Dictation

    private func startRecording() {
        guard !recording, finishTailTask == nil else { return }
        let relay = CaptureRelay()
        captureRelay = relay
        recorder.onCapture = { relay.receive($0) }

        do {
            try recorder.start()
        } catch {
            captureRelay = nil
            setStatus("Microphone unavailable")
            return
        }

        recording = true
        let opts = settings.snapshot()
        startLiveTask = Task { [weak self] in
            guard let self else { return }
            if let session = await self.pipeline.startLive(options: opts) {
                relay.attach(session)
            }
        }
        pipeline.wakeGPU()
        setIcon(.recording)
        hud.show(.listening)
    }

    private func finishRecording() {
        guard recording, finishTailTask == nil else { return }
        hud.show(.transcribing)
        let released = Date()
        let opts = settings.snapshot()

        finishTailTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let baseMs = max(80, opts.releaseTailMs)
            try? await Task.sleep(for: .milliseconds(baseMs))
            var extraMs = 0
            if opts.adaptiveReleaseTail {
                for _ in 0..<3 {
                    guard !Task.isCancelled, self.recorder.hasActiveTailSpeech() else { break }
                    try? await Task.sleep(for: .milliseconds(50))
                    extraMs += 50
                }
            }
            if extraMs > 0 {
                log.info("extended release tail by \(extraMs, privacy: .public)ms for trailing speech")
            }
            guard !Task.isCancelled, self.recording else { return }
            self.finishTailTask = nil

            let samples = self.recorder.stop()
            let rate = self.recorder.sampleRate
            let relay = self.captureRelay
            let liveStart = self.startLiveTask
            self.captureRelay = nil
            self.startLiveTask = nil
            self.recording = false
            self.setIcon(self.ready ? .idle : .loading)

            do {
                await self.modelLoad?.value
                _ = await liveStart?.value
                let session = relay?.cancel()

                let text: String
                let baseText: String
                let qwenText: String?
                let route: String
                let baseMsElapsed: Int
                let qwenMs: Int
                let fuseMs: Int
                let segments: Int
                let modelSummary: String
                let tailMs: Int

                if let session {
                    let outcome = try await session.finish(samples)
                    text = outcome.text
                    baseText = outcome.segments.map(\.baseText).joined(separator: " ")
                    let qParts = outcome.segments.compactMap(\.qwenText).filter { !$0.isEmpty }
                    qwenText = qParts.isEmpty ? nil : qParts.joined(separator: " ")
                    route = outcome.segments.last?.route ?? "none"
                    baseMsElapsed = outcome.segments.map(\.baseMs).reduce(0, +)
                    qwenMs = outcome.segments.map(\.qwenMs).reduce(0, +)
                    fuseMs = outcome.segments.map(\.fuseMs).reduce(0, +)
                    segments = outcome.segments.count
                    modelSummary = outcome.segments.last?.modelSummary ?? opts.baseModel.shortName
                    tailMs = outcome.tailMs
                } else {
                    let r = try await self.pipeline.transcribe(samples, options: opts)
                    text = r.text
                    baseText = r.baseText
                    qwenText = r.qwenText
                    route = r.route
                    baseMsElapsed = r.baseMs
                    qwenMs = r.qwenMs
                    fuseMs = r.fuseMs
                    segments = 1
                    modelSummary = r.modelSummary
                    tailMs = Int(Date().timeIntervalSince(released) * 1000)
                }

                let audioFile = Recordings.save(samples, sampleRate: rate, transcript: text)
                self.hud.hide()
                guard !text.isEmpty else { return }

                Paster.paste(text, spacing: opts.spacingMode)

                let audioSeconds = Double(samples.count) / rate
                let entry = HistoryEntry(
                    text: text,
                    baseText: baseText,
                    qwenText: qwenText,
                    route: route,
                    durationSeconds: audioSeconds,
                    tailMs: tailMs,
                    baseMs: baseMsElapsed,
                    qwenMs: qwenMs,
                    fuseMs: fuseMs,
                    segments: segments,
                    modelSummary: modelSummary,
                    audioFilename: audioFile
                )
                self.history.append(entry)

                let pasteMs = Int(Date().timeIntervalSince(released) * 1000)
                log.info("\(audioSeconds, format: .fixed(precision: 1), privacy: .public)s audio → \(pasteMs, privacy: .public)ms to paste; \(segments, privacy: .public) seg(s), \(route, privacy: .public)")
            } catch {
                self.hud.hide()
                log.error("transcription failed: \(error, privacy: .public)")
            }
        }
    }

    private func cancelRecording() {
        guard recording else { return }
        finishTailTask?.cancel()
        finishTailTask = nil
        _ = recorder.stop()
        let relay = captureRelay
        let liveStart = startLiveTask
        captureRelay = nil
        startLiveTask = nil
        Task {
            _ = await liveStart?.value
            if let session = relay?.cancel() {
                await session.cancel()
            }
        }
        recording = false
        setIcon(ready ? .idle : .loading)
        hud.hide()
    }

    // MARK: Setup & Sync

    private func syncHotkeySettings() {
        hotkey.binding = settings.dictationShortcut
        hotkey.triggerMode = settings.triggerMode
        hotkey.doubleTapLock = settings.doubleTapLock
        hotkey.pasteLastBinding = settings.pasteLastShortcut
        updateMenuStatusLine()
        if ready && !isSyncingModels {
            settingsWindow?.updateModelState(
                status: readyStatusText(),
                isSwitching: false,
                progress: nil,
                error: lastSyncError
            )
        }
    }

    private func syncRecorderSettings() {
        recorder.selectedDeviceUID = settings.selectedMicUID
        recorder.warmFor = TimeInterval(settings.keepMicWarmSeconds)
    }

    private func scheduleModelSync() {
        pendingModelSync = true
        guard !isSyncingModels else { return }
        isSyncingModels = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.pendingModelSync {
                self.pendingModelSync = false
                let opts = self.settings.snapshot()
                await self.runModelSync(opts)
            }
            self.isSyncingModels = false
            self.modelLoad = nil
        }
        modelLoad = task
    }

    private func runModelSync(_ opts: TuningOptions) async {
        let initialMessage = ready ? "Switching models…" : "Loading \(opts.baseModel.shortName)…"
        lastSyncError = nil
        activeSyncStatus = initialMessage
        settingsWindow?.updateModelState(
            status: initialMessage,
            isSwitching: true,
            progress: nil,
            error: nil
        )
        updateMenuStatusLine()

        let (stream, continuation) = AsyncStream.makeStream(of: Pipeline.ModelSyncEvent.self)
        let consumer = Task { @MainActor [weak self] in
            for await event in stream {
                self?.handleModelSyncEvent(event)
            }
        }
        await pipeline.syncModels(opts) { event in
            continuation.yield(event)
        }
        continuation.finish()
        await consumer.value
    }

    private func handleModelSyncEvent(_ event: Pipeline.ModelSyncEvent) {
        ready = event.baseReady
        if !recording {
            setIcon(ready ? .idle : .loading)
        }

        switch event.phase {
        case .loading:
            lastSyncError = nil
            activeSyncStatus = event.message
            settingsWindow?.updateModelState(
                status: event.message,
                isSwitching: true,
                progress: event.progress,
                error: nil
            )
        case .ready:
            lastSyncError = nil
            activeSyncStatus = nil
            settingsWindow?.updateModelState(
                status: readyStatusText(),
                isSwitching: false,
                progress: nil,
                error: nil,
                refreshMemory: true
            )
        case .error:
            lastSyncError = event.message
            activeSyncStatus = nil
            settingsWindow?.updateModelState(
                status: ready ? readyStatusText() : event.message,
                isSwitching: false,
                progress: nil,
                error: event.message,
                refreshMemory: true
            )
        }
        updateMenuStatusLine()
    }

    private func installHotkeyWhenTrusted() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary), hotkey.install() {
            hotkeyTrusted = true
            updateMenuStatusLine()
            return
        }
        hotkeyTrusted = false
        updateMenuStatusLine()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                guard AXIsProcessTrusted(), self.hotkey.install() else { return }
                timer.invalidate()
                self.hotkeyTrusted = true
                self.updateMenuStatusLine()
            }
        }
    }

    // MARK: Menus

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Koe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let historyItem = NSMenuItem(title: "History & Inspector…", action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        let vocabItem = NSMenuItem(title: "Vocabulary & Replacements…", action: #selector(openVocabulary), keyEquivalent: "")
        vocabItem.target = self
        menu.addItem(vocabItem)

        menu.addItem(.separator())

        pasteLastItem.target = self
        menu.addItem(pasteLastItem)

        let recentItem = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())

        hybridModeItem.target = self
        aneModeItem.target = self
        menu.addItem(hybridModeItem)
        menu.addItem(aneModeItem)

        menu.addItem(.separator())

        loginItem.target = self
        recordingsItem.target = self
        menu.addItem(loginItem)
        menu.addItem(recordingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Koe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        refreshModeMenuChecks()
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        recordingsItem.state = settings.saveRecordings ? .on : .off
        refreshModeMenuChecks()

        if let latest = history.entries.first {
            let preview = latest.text.count > 44 ? latest.text.prefix(44) + "…" : latest.text
            let keyText = settings.pasteLastShortcut.map { " (\($0.displayName))" } ?? ""
            pasteLastItem.title = "Paste Last\(keyText): \(preview)"
            pasteLastItem.isEnabled = true
        } else {
            pasteLastItem.title = "Nothing dictated yet"
            pasteLastItem.isEnabled = false
        }

        recentMenu.removeAllItems()
        let recent = Array(history.entries.prefix(5))
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No history yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        } else {
            for entry in recent {
                let preview = entry.text.count > 55 ? entry.text.prefix(55) + "…" : entry.text
                let item = NSMenuItem(title: preview, action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                recentMenu.addItem(item)
            }
        }
    }

    private func refreshModeMenuChecks() {
        hybridModeItem.state = settings.engineMode == .hybrid ? .on : .off
        aneModeItem.state = settings.engineMode == .aneSolo ? .on : .off
    }

    @objc private func openSettings() {
        settingsWindow?.open(tab: .general)
    }

    @objc private func openHistory() {
        settingsWindow?.open(tab: .history)
    }

    @objc private func openVocabulary() {
        settingsWindow?.open(tab: .vocabulary)
    }

    @objc private func selectHybridMode() {
        settings.engineMode = .hybrid
    }

    @objc private func selectANEMode() {
        settings.engineMode = .aneSolo
    }

    @objc private func pasteLast() {
        guard let latest = history.entries.first else { return }
        Paster.paste(latest.text, spacing: settings.spacingMode)
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
        settings.saveRecordings.toggle()
        recordingsItem.state = settings.saveRecordings ? .on : .off
    }

    private func readyPrompt() -> String {
        let key = settings.dictationShortcut.displayName
        return settings.triggerMode == .hold ? "Hold \(key) to dictate" : "Press \(key) to dictate"
    }

    private func readyStatusText() -> String {
        let modeLabel = settings.engineMode == .aneSolo ? "ANE Solo" : settings.fuserModel.displayName
        return "\(readyPrompt()) · \(modeLabel)"
    }

    private func updateMenuStatusLine() {
        if !hotkeyTrusted {
            statusLine.title = "Grant Accessibility access in System Settings"
            return
        }
        if let activeSyncStatus {
            statusLine.title = activeSyncStatus
        } else if ready {
            if lastSyncError != nil {
                statusLine.title = "\(readyStatusText()) (GPU fallback)"
            } else {
                statusLine.title = readyStatusText()
            }
        } else {
            statusLine.title = lastSyncError ?? "Model failed to load"
        }
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
        case .recording: NSColor(srgbRed: 0.84, green: 0.24, blue: 0.17, alpha: 1)
        }
        statusItem.button?.attributedTitle = NSAttributedString(string: "声", attributes: [
            .font: NSFont(name: "HiraMinProN-W6", size: 15) ?? .menuBarFont(ofSize: 15),
            .foregroundColor: color,
        ])
        statusItem.button?.setAccessibilityLabel("Koe")
    }
}
