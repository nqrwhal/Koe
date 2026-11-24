import AppKit
import AVFoundation
import Carbon.HIToolbox
import HuggingFace
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case models
    case tuning
    case vocabulary
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .models: return "Models & Memory"
        case .tuning: return "Tuning & Cleanup"
        case .vocabulary: return "Vocabulary"
        case .history: return "History & Inspector"
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .models: return "cpu"
        case .tuning: return "waveform.path.ecg"
        case .vocabulary: return "text.book.closed"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

@MainActor
final class SettingsWindowState: ObservableObject {
    @Published var selectedTab: SettingsTab = .general
    @Published var modelStatusText: String = "Starting…"
    @Published var isSwitchingModels: Bool = false
    @Published var modelProgress: Double?
    @Published var modelErrorText: String?
    @Published var availableMics: [Recorder.AudioInputDevice] = []
    @Published var memorySnapshot = MemoryMonitor.current()
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let state = SettingsWindowState()
    private var memoryTimer: Timer?

    private let settings: AppSettings
    private let history: HistoryStore
    private let pipeline: Pipeline
    private let hotkey: Hotkey
    private let onPasteHistory: (String) -> Void
    private let onModelReloadRequested: () -> Void
    private let onVocabularyChanged: () -> Void

    init(
        settings: AppSettings,
        history: HistoryStore,
        pipeline: Pipeline,
        hotkey: Hotkey,
        onPasteHistory: @escaping (String) -> Void,
        onModelReloadRequested: @escaping () -> Void,
        onVocabularyChanged: @escaping () -> Void
    ) {
        self.settings = settings
        self.history = history
        self.pipeline = pipeline
        self.hotkey = hotkey
        self.onPasteHistory = onPasteHistory
        self.onModelReloadRequested = onModelReloadRequested
        self.onVocabularyChanged = onVocabularyChanged
        super.init()
    }

    func updateModelState(
        status: String,
        isSwitching: Bool,
        progress: Double?,
        error: String?,
        refreshMemory: Bool = false
    ) {
        state.modelStatusText = status
        state.isSwitchingModels = isSwitching
        state.modelProgress = progress
        state.modelErrorText = error
        if refreshMemory {
            state.memorySnapshot = MemoryMonitor.current()
        }
    }

    func open(tab: SettingsTab = .general) {
        state.selectedTab = tab
        state.availableMics = Recorder.availableInputDevices()
        state.memorySnapshot = MemoryMonitor.current()

        if window == nil {
            let root = SettingsRootView(
                state: state,
                settings: settings,
                history: history,
                pipeline: pipeline,
                hotkey: hotkey,
                onPasteHistory: { [weak self] text in
                    self?.window?.orderOut(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self?.onPasteHistory(text)
                    }
                },
                onModelReloadRequested: onModelReloadRequested,
                onVocabularyChanged: onVocabularyChanged
            )
            let hosting = NSHostingController(rootView: root)
            let win = NSWindow(contentViewController: hosting)
            win.title = "Koe"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.setContentSize(NSSize(width: 860, height: 620))
            win.minSize = NSSize(width: 760, height: 520)
            win.center()
            win.isReleasedWhenClosed = false
            win.delegate = self
            self.window = win
        }

        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startMemoryPolling()
    }

    func windowWillClose(_ notification: Notification) {
        stopMemoryPolling()
        hotkey.isSuspended = false
        NSApp.setActivationPolicy(.accessory)
    }

    private func startMemoryPolling() {
        stopMemoryPolling()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.state.memorySnapshot = MemoryMonitor.current()
            }
        }
    }

    private func stopMemoryPolling() {
        memoryTimer?.invalidate()
        memoryTimer = nil
    }
}

// MARK: - Root View

private struct SettingsRootView: View {
    @ObservedObject var state: SettingsWindowState
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore
    let pipeline: Pipeline
    let hotkey: Hotkey
    let onPasteHistory: (String) -> Void
    let onModelReloadRequested: () -> Void
    let onVocabularyChanged: () -> Void

    private let vermilion = Color(.sRGB, red: 0.80, green: 0.22, blue: 0.16)

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(vermilion)
                            .frame(width: 30, height: 30)
                        Text("声")
                            .font(.custom("HiraMinProN-W6", size: 17))
                            .foregroundStyle(Color(.sRGB, red: 0.98, green: 0.94, blue: 0.88))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Koe")
                            .font(.headline)
                        Text("\(state.memorySnapshot.footprintMB) MB RAM")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)

                List(SettingsTab.allCases) { tab in
                    let selected = state.selectedTab == tab
                    Button {
                        state.selectedTab = tab
                    } label: {
                        Label(tab.title, systemImage: tab.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
                            )
                            .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                    .listRowSeparator(.hidden)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 195, ideal: 215, max: 240)
        } detail: {
            Group {
                switch state.selectedTab {
                case .general:
                    GeneralSettingsView(state: state, settings: settings, hotkey: hotkey)
                case .models:
                    ModelsSettingsView(state: state, settings: settings, pipeline: pipeline, onApply: onModelReloadRequested)
                case .tuning:
                    TuningSettingsView(settings: settings)
                case .vocabulary:
                    VocabularySettingsView(onVocabularyChanged: onVocabularyChanged)
                case .history:
                    HistoryInspectorView(
                        history: history,
                        onPaste: onPasteHistory,
                        onVocabularyChanged: onVocabularyChanged
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 1. General Tab

private struct GeneralSettingsView: View {
    @ObservedObject var state: SettingsWindowState
    @ObservedObject var settings: AppSettings
    let hotkey: Hotkey

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Dictation Shortcut") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Primary Shortcut")
                        Text("Hold to speak, or tap twice to lock hands-free. Press Esc anytime to cancel.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if settings.dictationShortcut.kind == .modifierOnly,
                       let mod = settings.dictationShortcut.primaryModifier,
                       mod != .fn
                    {
                        Picker("", selection: Binding(
                            get: { settings.dictationShortcut.side },
                            set: { newSide in
                                var copy = settings.dictationShortcut
                                copy.side = newSide
                                settings.dictationShortcut = copy
                            }
                        )) {
                            ForEach(KeyBinding.Side.allCases, id: \.self) { side in
                                Text(side.label).tag(side)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 92)
                    }
                    ShortcutRecorderButton(
                        binding: Binding(
                            get: { settings.dictationShortcut },
                            set: { if let val = $0 { settings.dictationShortcut = val } }
                        ),
                        allowClear: false,
                        defaultBinding: .defaultDictation,
                        hotkey: hotkey
                    )
                }

                Picker("Trigger Mode", selection: $settings.triggerMode) {
                    ForEach(TriggerMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if settings.triggerMode == .hold {
                    Toggle("Double-tap shortcut to lock hands-free recording", isOn: $settings.doubleTapLock)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paste Last Dictation")
                        Text("Re-pastes the most recent transcript anywhere.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShortcutRecorderButton(
                        binding: $settings.pasteLastShortcut,
                        allowClear: true,
                        defaultBinding: .defaultPasteLast,
                        hotkey: hotkey
                    )
                }
            }

            Section("Audio Input") {
                HStack {
                    Picker("Microphone", selection: $settings.selectedMicUID) {
                        Text("System Default").tag(String?.none)
                        ForEach(state.availableMics) { mic in
                            Text(mic.name).tag(Optional(mic.uid))
                        }
                    }
                    Button {
                        state.availableMics = Recorder.availableInputDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh microphone list")
                }

                Picker("Keep Microphone Warm", selection: $settings.keepMicWarmSeconds) {
                    Text("Off (Zero Idle Mic)").tag(0)
                    Text("1 minute").tag(60)
                    Text("3 minutes (Instant Pre-roll)").tag(180)
                    Text("5 minutes").tag(300)
                }
            }

            Section("Application") {
                Toggle("Launch Koe at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }

                Toggle("Save Audio & Transcripts Locally for Tuning", isOn: $settings.saveRecordings)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

private struct ShortcutRecorderButton: View {
    @Binding var binding: KeyBinding?
    let allowClear: Bool
    let defaultBinding: KeyBinding
    let hotkey: Hotkey

    @State private var recording = false
    @State private var previewText = "Press keys…"
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if binding != defaultBinding {
                Button("Reset") {
                    binding = defaultBinding
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button {
                if recording { stopRecording() } else { startRecording() }
            } label: {
                Text(recording ? previewText : (binding?.displayName ?? "Off"))
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .frame(minWidth: 112)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(recording ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(recording ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(allowClear ? "Click to record shortcut (Esc cancels, Backspace turns off)" : "Click to record shortcut (Esc cancels)")
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        previewText = allowClear ? "Press keys (⌫ off)…" : "Press shortcut…"
        hotkey.isSuspended = true
        var lastModifierCandidate: (modifier: KeyBinding.Modifier, side: KeyBinding.Side)?

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown {
                let code = Int64(event.keyCode)
                if code == Int64(kVK_Escape) {
                    stopRecording()
                    return nil
                }
                if allowClear && (code == Int64(kVK_Delete) || code == Int64(kVK_ForwardDelete)) && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                    binding = nil
                    stopRecording()
                    return nil
                }

                let mods = activeModifiers(from: event.modifierFlags)
                let isFnOrFKey = (Int(code) >= kVK_F1 && Int(code) <= kVK_F20) || code == 176
                if allowClear && mods.isEmpty && !isFnOrFKey {
                    previewText = "Add a modifier…"
                    return nil
                }
                let label = KeyBinding.keyName(for: code, charactersIgnoringModifiers: event.charactersIgnoringModifiers)
                binding = KeyBinding(
                    kind: .keyChord,
                    primaryModifier: nil,
                    side: .either,
                    modifiers: mods,
                    keyCode: code,
                    keyLabel: label
                )
                stopRecording()
                return nil
            }

            if event.type == .flagsChanged {
                let code = Int64(event.keyCode)
                let mods = activeModifiers(from: event.modifierFlags)
                let hasFn = event.modifierFlags.contains(.function)

                if let parsed = KeyBinding.Modifier.from(keyCode: code) {
                    let isNowDown: Bool
                    if parsed.modifier == .fn {
                        isNowDown = hasFn
                    } else {
                        isNowDown = event.modifierFlags.contains(nsFlag(for: parsed.modifier))
                    }
                    if isNowDown {
                        lastModifierCandidate = parsed
                        previewText = mods.map(\.symbol).joined() + (hasFn && !mods.contains(.fn) ? "Fn" : "")
                    } else if let candidate = lastModifierCandidate, candidate.modifier == parsed.modifier, !allowClear {
                        binding = KeyBinding(
                            kind: .modifierOnly,
                            primaryModifier: candidate.modifier,
                            side: candidate.side,
                            modifiers: [candidate.modifier],
                            keyCode: code,
                            keyLabel: nil
                        )
                        stopRecording()
                        return nil
                    }
                } else {
                    previewText = mods.isEmpty ? "Press shortcut…" : mods.map(\.symbol).joined()
                }
            }
            return event
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recording = false
        hotkey.isSuspended = false
    }

    private func activeModifiers(from flags: NSEvent.ModifierFlags) -> [KeyBinding.Modifier] {
        var list: [KeyBinding.Modifier] = []
        if flags.contains(.control) { list.append(.control) }
        if flags.contains(.option) { list.append(.option) }
        if flags.contains(.shift) { list.append(.shift) }
        if flags.contains(.command) { list.append(.command) }
        return list
    }

    private func nsFlag(for mod: KeyBinding.Modifier) -> NSEvent.ModifierFlags {
        switch mod {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        case .fn: return .function
        }
    }
}

// MARK: - 2. Models & Memory Tab

private struct ModelsSettingsView: View {
    @ObservedObject var state: SettingsWindowState
    @ObservedObject var settings: AppSettings
    let pipeline: Pipeline
    let onApply: () -> Void

    var body: some View {
        Form {
            Section("Live Memory & Status") {
                HStack(spacing: 16) {
                    MetricBadge(label: "Process Footprint", value: "\(state.memorySnapshot.footprintMB) MB")
                    MetricBadge(label: "MLX Active", value: "\(state.memorySnapshot.mlxActiveMB) MB")
                    MetricBadge(label: "MLX Cache", value: "\(state.memorySnapshot.mlxCacheMB) MB")
                    Spacer()
                    Button("Unload GPU") {
                        Task {
                            await pipeline.unloadGPU()
                            state.memorySnapshot = MemoryMonitor.current()
                        }
                    }
                    .disabled(state.isSwitchingModels || (state.memorySnapshot.mlxActiveMB == 0 && state.memorySnapshot.mlxCacheMB == 0))
                }

                LabeledContent("Pipeline Status") {
                    HStack(spacing: 8) {
                        if state.isSwitchingModels {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(state.modelStatusText)
                            .foregroundStyle(state.isSwitchingModels ? .primary : .secondary)
                    }
                }

                if let progress = state.modelProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }

                if let errorText = state.modelErrorText {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") {
                            onApply()
                        }
                        .controlSize(.small)
                        .disabled(state.isSwitchingModels)
                    }
                }
            }

            Section("Quick Presets") {
                ForEach(PipelinePreset.presets) { preset in
                    let isSelected = settings.engineMode == preset.engineMode
                        && settings.baseModel == preset.baseModel
                        && (preset.engineMode == .aneSolo || settings.fuserModel == preset.fuserModel)
                        && settings.ctcVocabBoosting == preset.ctcBoosting
                    Button {
                        settings.applyPreset(preset)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(preset.title).font(.headline)
                                    Text(preset.memoryBadge)
                                        .font(.caption.monospacedDigit())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                }
                                Text(preset.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Custom Stack & Idle Memory") {
                Picker("Engine Mode", selection: $settings.engineMode) {
                    ForEach(EngineMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Picker("Base Recognizer (ANE)", selection: $settings.baseModel) {
                    ForEach(BaseModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                Text(settings.baseModel.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.engineMode == .aneSolo {
                    Toggle("Personal Vocabulary CTC Boosting (+106 MB)", isOn: $settings.ctcVocabBoosting)
                } else {
                    Picker("Fuser LLM (GPU)", selection: $settings.fuserModel) {
                        ForEach(FuserModel.allCases) { model in
                            Text("\(model.displayName) · \(model.sizeSummary)").tag(model)
                        }
                    }

                    Picker("Idle GPU Auto-Unload", selection: $settings.idleUnloadMinutes) {
                        Text("Never").tag(0)
                        Text("After 5 minutes").tag(5)
                        Text("After 10 minutes").tag(10)
                        Text("After 15 minutes").tag(15)
                        Text("After 30 minutes").tag(30)
                    }
                }

                HStack {
                    Text("Changes apply automatically in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reload Active Models") {
                        onApply()
                    }
                    .disabled(state.isSwitchingModels)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Models & Memory")
    }
}

private struct MetricBadge: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: - 3. Tuning & Cleanup Tab

private struct TuningSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var sampleInput = "Um, I want to use the the tuning,s for whisper flow. and dot env"

    private var previewOutput: String {
        let personal = Vocabulary.loadPersonal()
        let terms = personal + Vocabulary.builtIn
        let speller = Speller(terms: terms, personal: personal)
        let normalized = speller.normalize(sampleInput)
        return TextCleaner.clean(
            normalized,
            options: settings.snapshot(),
            lowercasePreservingTerms: terms,
            replacements: ReplacementStore.load()
        )
    }

    var body: some View {
        Form {
            Section("Sentence Segmentation") {
                if settings.engineMode == .aneSolo && settings.baseModel.supportsNativeStreaming {
                    Label(
                        "Continuous Neural Engine streaming is active — speech is never split at pauses, so sentences are never truncated.",
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Toggle("Whole Dictation (disable pause cuts under 30s)", isOn: $settings.wholeDictationOnly)

                if !settings.wholeDictationOnly {
                    HStack {
                        Text("Minimum Segment Before Pause Cut")
                        Spacer()
                        Text("\(Int(settings.minSegmentSeconds)) s").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.minSegmentSeconds, in: 6...30, step: 1)

                    HStack {
                        Text("Pause Length Required to Cut")
                        Spacer()
                        Text(String(format: "%.1f s", settings.pauseThresholdSeconds)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.pauseThresholdSeconds, in: 0.8...2.5, step: 0.1)
                }
            }

            Section("Punctuation & Cleanup") {
                Toggle("Smart punctuation repair (e.g. \"tuning,s\" → \"tunings,\", \". if\" → \". If\")", isOn: $settings.smartPunctuationCleanup)
                Toggle("Strip hesitation fillers (um, uh, erm, hmm)", isOn: $settings.removeFillers)
                Toggle("Collapse immediate stutters (\"the the\" → \"the\")", isOn: $settings.collapseStutters)

                Picker("Paste Spacing", selection: $settings.spacingMode) {
                    ForEach(SpacingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(settings.spacingMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Try Cleanup Live") {
                TextField("Type or paste messy ASR text…", text: $sampleInput, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                LabeledContent("Output") {
                    Text(previewOutput)
                        .font(.body.weight(.medium))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Tuning & Cleanup")
    }
}

// MARK: - 4. Vocabulary & Replacements Tab

private struct VocabularySettingsView: View {
    let onVocabularyChanged: () -> Void

    @State private var personalTerms: [String] = []
    @State private var newTerm = ""
    @State private var replacements: [WordReplacement] = []
    @State private var newSpoken = ""
    @State private var newWritten = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Add custom word or name (e.g. Wispr Flow, kubectl)…", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm)
                        .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if personalTerms.isEmpty {
                    Text("No custom terms yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(personalTerms.enumerated()), id: \.offset) { idx, term in
                        HStack {
                            Text(term)
                            Spacer()
                            Button(role: .destructive) {
                                personalTerms.remove(at: idx)
                                persistTerms()
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack {
                    Text("Saved in vocabulary.txt · applied live without restarting Koe.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reveal File") {
                        NSWorkspace.shared.activateFileViewerSelecting([Vocabulary.url])
                    }
                    .font(.caption)
                }
            } header: {
                Text("Personal Vocabulary")
            }

            Section {
                HStack {
                    TextField("Spoken (e.g. dot env)", text: $newSpoken)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("Written (e.g. .env)", text: $newWritten)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addReplacement)
                    Button("Add", action: addReplacement)
                        .disabled(
                            newSpoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || newWritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }

                ForEach($replacements) { $rule in
                    HStack {
                        Toggle("", isOn: $rule.enabled)
                            .labelsHidden()
                            .onChange(of: rule.enabled) { _, _ in persistReplacements() }
                        Text(rule.spoken)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(rule.written)
                            .fontWeight(.medium)
                        Spacer()
                        Button(role: .destructive) {
                            replacements.removeAll { $0.id == rule.id }
                            persistReplacements()
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Word Replacements")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Vocabulary")
        .onAppear {
            personalTerms = Vocabulary.loadPersonal()
            replacements = ReplacementStore.load()
        }
    }

    private func addTerm() {
        let trimmed = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !personalTerms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            personalTerms.append(trimmed)
            persistTerms()
        }
        newTerm = ""
    }

    private func persistTerms() {
        Vocabulary.savePersonal(personalTerms)
        onVocabularyChanged()
    }

    private func addReplacement() {
        let spoken = newSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = newWritten.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty, !written.isEmpty else { return }
        replacements.append(WordReplacement(spoken: spoken, written: written))
        newSpoken = ""
        newWritten = ""
        persistReplacements()
    }

    private func persistReplacements() {
        ReplacementStore.save(replacements)
        onVocabularyChanged()
    }
}

// MARK: - 5. History & Inspector Tab

private struct HistoryInspectorView: View {
    @ObservedObject var history: HistoryStore
    let onPaste: (String) -> Void
    let onVocabularyChanged: () -> Void

    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playingID: UUID?
    @State private var quickTerm = ""
    @State private var quickAddedMessage: String?

    private var filtered: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.text.lowercased().contains(q)
                || $0.baseText.lowercased().contains(q)
                || ($0.qwenText?.lowercased().contains(q) ?? false)
        }
    }

    private var selected: HistoryEntry? {
        if let selectedID, let found = filtered.first(where: { $0.id == selectedID }) {
            return found
        }
        return filtered.first
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search history…", text: $query)
                        .textFieldStyle(.plain)
                    if !history.entries.isEmpty {
                        Button("Clear") {
                            history.clearAll()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
                .padding(10)
                Divider()

                if filtered.isEmpty {
                    ContentUnavailableView("No Dictations Yet", systemImage: "waveform", description: Text("Hold your shortcut and speak to record."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered, selection: $selectedID) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.text)
                                .lineLimit(2)
                                .font(.callout)
                            HStack(spacing: 6) {
                                RouteBadge(route: entry.route)
                                Text("\(entry.tailMs) ms")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.timestamp, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(entry.id)
                    }
                }
            }
            .frame(minWidth: 250, idealWidth: 280, maxWidth: 340)

            Group {
                if let entry = selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.headline)
                                    Text("\(String(format: "%.1fs", entry.durationSeconds)) audio · \(entry.segments) segment(s) · \(entry.modelSummary)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let wavName = entry.audioFilename {
                                    let wavURL = Recordings.folder.appendingPathComponent(wavName)
                                    if FileManager.default.fileExists(atPath: wavURL.path) {
                                        Button {
                                            toggleAudio(url: wavURL, id: entry.id)
                                        } label: {
                                            Label(playingID == entry.id ? "Stop" : "Play", systemImage: playingID == entry.id ? "stop.fill" : "play.fill")
                                        }
                                    }
                                }
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.text, forType: .string)
                                }
                                Button("Paste") {
                                    onPaste(entry.text)
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            HStack(spacing: 12) {
                                RouteBadge(route: entry.route)
                                Text("Release wait: \(entry.tailMs) ms")
                                    .font(.caption.monospacedDigit())
                                if entry.baseMs > 0 {
                                    Text("Base: \(entry.baseMs) ms")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                if entry.qwenMs > 0 {
                                    Text("Qwen: \(entry.qwenMs) ms")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                if entry.fuseMs > 0 {
                                    Text("Fuser: \(entry.fuseMs) ms")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }

                            GroupBox("Final Transcript") {
                                Text(entry.text)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(4)
                            }

                            GroupBox("Pipeline Diff Inspector") {
                                VStack(alignment: .leading, spacing: 10) {
                                    DiffRow(label: "Base ANE → Final", diff: wordDiff(from: entry.baseText, to: entry.text))
                                    if let qwenText = entry.qwenText, !qwenText.isEmpty {
                                        Divider()
                                        DiffRow(label: "Qwen3-ASR → Final", diff: wordDiff(from: qwenText, to: entry.text))
                                    }
                                }
                                .padding(4)
                            }

                            GroupBox("Quick Vocabulary Add") {
                                HStack {
                                    TextField("Term to remember (e.g. Wispr Flow)…", text: $quickTerm)
                                        .textFieldStyle(.roundedBorder)
                                    Button("Add to Vocabulary") {
                                        let t = quickTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                                        guard !t.isEmpty else { return }
                                        var list = Vocabulary.loadPersonal()
                                        if !list.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
                                            list.append(t)
                                            Vocabulary.savePersonal(list)
                                            onVocabularyChanged()
                                        }
                                        quickAddedMessage = "Added \"\(t)\""
                                        quickTerm = ""
                                    }
                                    .disabled(quickTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                                .padding(4)
                                if let quickAddedMessage {
                                    Text(quickAddedMessage)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)
                                }
                            }
                        }
                        .padding(16)
                    }
                } else {
                    ContentUnavailableView("Select a Dictation", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("History & Inspector")
        .onDisappear {
            audioPlayer?.stop()
            playingID = nil
        }
    }

    private func toggleAudio(url: URL, id: UUID) {
        if playingID == id {
            audioPlayer?.stop()
            playingID = nil
            return
        }
        audioPlayer?.stop()
        if let player = try? AVAudioPlayer(contentsOf: url) {
            audioPlayer = player
            playingID = id
            player.play()
        }
    }

    private func wordDiff(from source: String, to target: String) -> AttributedString {
        let a = source.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = target.split(whereSeparator: \.isWhitespace).map(String.init)
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out = AttributedString()
        func append(_ token: String, color: Color? = nil, strike: Bool = false) {
            if !out.characters.isEmpty { out.append(AttributedString(" ")) }
            var piece = AttributedString(token)
            if let color { piece.foregroundColor = color }
            if strike { piece.strikethroughStyle = .single }
            out.append(piece)
        }
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                append(b[j])
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                append(a[i], color: .red, strike: true)
                i += 1
            } else {
                append(b[j], color: .green)
                j += 1
            }
        }
        while i < a.count { append(a[i], color: .red, strike: true); i += 1 }
        while j < b.count { append(b[j], color: .green); j += 1 }
        return out
    }
}

private struct DiffRow: View {
    let label: String
    let diff: AttributedString

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(diff)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RouteBadge: View {
    let route: String

    var color: Color {
        switch route {
        case "ane-solo": return .blue
        case "agree": return .green
        case "fuse": return .orange
        default: return .secondary
        }
    }

    var body: some View {
        Text(route)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}
