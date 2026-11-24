import Carbon.HIToolbox
import CoreGraphics
import Foundation
import SwiftUI

enum EngineMode: String, Codable, CaseIterable, Identifiable {
    case aneSolo = "ane-solo"
    case hybrid = "hybrid"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aneSolo: return "ANE Solo (Ultra-Low Memory)"
        case .hybrid: return "Hybrid Dual-Model (ANE + GPU)"
        }
    }

    var subtitle: String {
        switch self {
        case .aneSolo: return "Parakeet Unified on Neural Engine + CTC Vocabulary Boosting"
        case .hybrid: return "Base ANE model + Qwen3-ASR in parallel + LLM fusion on disagreements"
        }
    }
}

enum BaseModel: String, Codable, CaseIterable, Identifiable {
    case parakeetUnifiedStreaming = "unified-stream"
    case parakeetUnifiedBatch = "unified-batch"
    case bark3Clean = "bark"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeetUnifiedStreaming: return "Parakeet Unified 0.6B (Streaming)"
        case .parakeetUnifiedBatch: return "Parakeet Unified 0.6B (15s Batch)"
        case .bark3Clean: return "Bark 3.0 Clean (Legacy)"
        }
    }

    var shortName: String {
        switch self {
        case .parakeetUnifiedStreaming: return "Parakeet Unified"
        case .parakeetUnifiedBatch: return "Parakeet Unified Batch"
        case .bark3Clean: return "Bark 3.0 Clean"
        }
    }

    var detail: String {
        switch self {
        case .parakeetUnifiedStreaming:
            return "Continuous streaming RNNT on Neural Engine; native punctuation, no pause truncation (~400 MB)"
        case .parakeetUnifiedBatch:
            return "15s overlapping full-attention window on Neural Engine; highest standalone accuracy (~600 MB)"
        case .bark3Clean:
            return "Parakeet TDT v3 fine-tune that drops fillers/repeats (~410 MB)"
        }
    }

    var supportsNativeStreaming: Bool {
        self == .parakeetUnifiedStreaming
    }

    var hasNativePunctuation: Bool {
        self == .parakeetUnifiedStreaming || self == .parakeetUnifiedBatch
    }
}

enum FuserModel: String, Codable, CaseIterable, Identifiable {
    case qwen3_0_6b = "qwen3-0.6b"
    case qwen3_5_0_8b = "qwen3.5-0.8b"
    case qwen3_1_7b = "qwen3-1.7b"
    case gemma4_e2b = "gemma4-e2b"
    case gemma4_e4b = "gemma4-e4b"

    var id: String { rawValue }

    enum Family {
        case qwen3
        case qwen35
        case gemma4
    }

    var family: Family {
        switch self {
        case .qwen3_0_6b, .qwen3_1_7b: return .qwen3
        case .qwen3_5_0_8b: return .qwen35
        case .gemma4_e2b, .gemma4_e4b: return .gemma4
        }
    }

    var repoID: String {
        switch self {
        case .qwen3_0_6b: return "mlx-community/Qwen3-0.6B-4bit"
        case .qwen3_5_0_8b: return "mlx-community/Qwen3.5-0.8B-4bit"
        case .qwen3_1_7b: return "mlx-community/Qwen3-1.7B-4bit"
        case .gemma4_e2b: return "mlx-community/gemma-4-e2b-it-4bit"
        case .gemma4_e4b: return "mlx-community/gemma-4-e4b-it-4bit"
        }
    }

    var displayName: String {
        switch self {
        case .qwen3_0_6b: return "Qwen3 0.6B (4-bit)"
        case .qwen3_5_0_8b: return "Qwen3.5 0.8B (4-bit)"
        case .qwen3_1_7b: return "Qwen3 1.7B (4-bit)"
        case .gemma4_e2b: return "Gemma 4 E2B (4-bit)"
        case .gemma4_e4b: return "Gemma 4 E4B (4-bit)"
        }
    }

    var downloadBytes: Int {
        switch self {
        case .qwen3_0_6b: return 351_000_000
        case .qwen3_5_0_8b: return 652_000_000
        case .qwen3_1_7b: return 984_000_000
        case .gemma4_e2b: return 3_583_000_000
        case .gemma4_e4b: return 5_179_000_000
        }
    }

    var sizeSummary: String {
        switch self {
        case .qwen3_0_6b: return "~0.35 GB disk"
        case .qwen3_5_0_8b: return "~0.65 GB disk"
        case .qwen3_1_7b: return "~0.98 GB disk"
        case .gemma4_e2b: return "~3.58 GB disk"
        case .gemma4_e4b: return "~5.18 GB disk"
        }
    }
}

enum TriggerMode: String, Codable, CaseIterable, Identifiable {
    case hold = "hold"
    case tapToToggle = "toggle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hold: return "Hold to Talk"
        case .tapToToggle: return "Tap to Toggle"
        }
    }
}

enum SpacingMode: String, Codable, CaseIterable, Identifiable {
    case smart = "smart"
    case trailingSpace = "trailing"
    case none = "none"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart: return "Smart Context Spacing"
        case .trailingSpace: return "Always Append Trailing Space"
        case .none: return "No Extra Spaces"
        }
    }

    var description: String {
        switch self {
        case .smart:
            return "Reads the character before the cursor via Accessibility to add a leading space only when needed, avoiding \"word .\" gaps."
        case .trailingSpace:
            return "Always appends a single space after pasted text."
        case .none:
            return "Pastes the transcript verbatim with no extra leading or trailing space."
        }
    }
}

struct KeyBinding: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case modifierOnly
        case keyChord
    }

    enum Modifier: String, Codable, CaseIterable {
        case command
        case option
        case control
        case shift
        case fn

        var symbol: String {
            switch self {
            case .command: return "⌘"
            case .option: return "⌥"
            case .control: return "⌃"
            case .shift: return "⇧"
            case .fn: return "Fn"
            }
        }

        var label: String {
            switch self {
            case .command: return "Command"
            case .option: return "Option"
            case .control: return "Control"
            case .shift: return "Shift"
            case .fn: return "Fn / Globe"
            }
        }

        var generalFlagMask: UInt64 {
            switch self {
            case .command: return CGEventFlags.maskCommand.rawValue
            case .option: return CGEventFlags.maskAlternate.rawValue
            case .control: return CGEventFlags.maskControl.rawValue
            case .shift: return CGEventFlags.maskShift.rawValue
            case .fn: return CGEventFlags.maskSecondaryFn.rawValue
            }
        }

        func deviceFlagMask(side: Side) -> UInt64 {
            switch (self, side) {
            case (.command, .left): return 0x0008
            case (.command, .right): return 0x0010
            case (.command, .either): return CGEventFlags.maskCommand.rawValue
            case (.option, .left): return 0x0020
            case (.option, .right): return 0x0040
            case (.option, .either): return CGEventFlags.maskAlternate.rawValue
            case (.control, .left): return 0x0001
            case (.control, .right): return 0x2000
            case (.control, .either): return CGEventFlags.maskControl.rawValue
            case (.shift, .left): return 0x0002
            case (.shift, .right): return 0x0004
            case (.shift, .either): return CGEventFlags.maskShift.rawValue
            case (.fn, _): return CGEventFlags.maskSecondaryFn.rawValue
            }
        }

        func matchesKeyCode(_ code: Int64, side: Side) -> Bool {
            switch (self, side) {
            case (.command, .left): return code == 55
            case (.command, .right): return code == 54
            case (.command, .either): return code == 54 || code == 55
            case (.option, .left): return code == 58
            case (.option, .right): return code == 61
            case (.option, .either): return code == 58 || code == 61
            case (.control, .left): return code == 59
            case (.control, .right): return code == 62
            case (.control, .either): return code == 59 || code == 62
            case (.shift, .left): return code == 56
            case (.shift, .right): return code == 60
            case (.shift, .either): return code == 56 || code == 60
            case (.fn, _): return code == 63 || code == 179
            }
        }

        static func from(keyCode: Int64) -> (modifier: Modifier, side: Side)? {
            switch keyCode {
            case 54: return (.command, .right)
            case 55: return (.command, .left)
            case 61: return (.option, .right)
            case 58: return (.option, .left)
            case 62: return (.control, .right)
            case 59: return (.control, .left)
            case 60: return (.shift, .right)
            case 56: return (.shift, .left)
            case 63, 179: return (.fn, .either)
            default: return nil
            }
        }
    }

    enum Side: String, Codable, CaseIterable {
        case left
        case right
        case either

        var label: String {
            switch self {
            case .left: return "Left"
            case .right: return "Right"
            case .either: return "Either"
            }
        }
    }

    var kind: Kind
    var primaryModifier: Modifier?
    var side: Side
    var modifiers: [Modifier]
    var keyCode: Int64?
    var keyLabel: String?

    static let defaultDictation = KeyBinding(
        kind: .modifierOnly,
        primaryModifier: .command,
        side: .right,
        modifiers: [.command],
        keyCode: 54,
        keyLabel: nil
    )

    static let defaultPasteLast = KeyBinding(
        kind: .keyChord,
        primaryModifier: nil,
        side: .either,
        modifiers: [.option, .shift],
        keyCode: Int64(kVK_ANSI_V),
        keyLabel: "V"
    )

    var displayName: String {
        switch kind {
        case .modifierOnly:
            guard let mod = primaryModifier else { return "Unassigned" }
            if mod == .fn { return "Fn / Globe" }
            switch side {
            case .left: return "Left \(mod.symbol)"
            case .right: return "Right \(mod.symbol)"
            case .either: return mod.symbol
            }
        case .keyChord:
            let mods = modifiers.map(\.symbol).joined()
            return mods + (keyLabel ?? "Key \(keyCode ?? 0)")
        }
    }

    var keycaps: [String] {
        switch kind {
        case .modifierOnly:
            return [displayName]
        case .keyChord:
            return modifiers.map(\.symbol) + [keyLabel ?? "?"]
        }
    }

    static func keyName(for keyCode: Int64, charactersIgnoringModifiers: String?) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "Esc"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        case 176: return "Mic"
        case 179: return "Fn"
        default:
            if let chars = charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines), !chars.isEmpty {
                return chars.uppercased()
            }
            return "Key \(keyCode)"
        }
    }
}

struct PipelinePreset: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let memoryBadge: String
    let engineMode: EngineMode
    let baseModel: BaseModel
    let fuserModel: FuserModel
    let ctcBoosting: Bool

    static let presets: [PipelinePreset] = [
        PipelinePreset(
            id: "ane-solo",
            title: "ANE Solo (Hex-style)",
            subtitle: "Parakeet Unified streaming + personal CTC boosting. Zero GPU RAM, ~30–150 ms.",
            memoryBadge: "~0.1 GB RAM",
            engineMode: .aneSolo,
            baseModel: .parakeetUnifiedStreaming,
            fuserModel: .qwen3_0_6b,
            ctcBoosting: true
        ),
        PipelinePreset(
            id: "ultra-light",
            title: "Ultra-Light Hybrid",
            subtitle: "Parakeet Unified ∥ Qwen3-ASR 0.6B → Qwen3 0.6B fuser (~540 ms median).",
            memoryBadge: "~2.2 GB peak",
            engineMode: .hybrid,
            baseModel: .parakeetUnifiedStreaming,
            fuserModel: .qwen3_0_6b,
            ctcBoosting: false
        ),
        PipelinePreset(
            id: "balanced",
            title: "Balanced Hybrid (Recommended)",
            subtitle: "Parakeet Unified ∥ Qwen3-ASR 0.6B → Qwen3 1.7B fuser (~480 ms median).",
            memoryBadge: "~2.4 GB peak",
            engineMode: .hybrid,
            baseModel: .parakeetUnifiedStreaming,
            fuserModel: .qwen3_1_7b,
            ctcBoosting: false
        ),
        PipelinePreset(
            id: "gemma-e2b",
            title: "Gemma 4 E2B Hybrid",
            subtitle: "Parakeet Unified ∥ Qwen3-ASR 0.6B → Gemma 4 E2B fuser (~2.5 s median).",
            memoryBadge: "~4.3 GB peak",
            engineMode: .hybrid,
            baseModel: .parakeetUnifiedStreaming,
            fuserModel: .gemma4_e2b,
            ctcBoosting: false
        ),
    ]
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let engineMode = "koe.engineMode"
        static let baseModel = "koe.baseModel"
        static let fuserModel = "koe.fuserModel"
        static let ctcVocabBoosting = "koe.ctcVocabBoosting"
        static let idleUnloadMinutes = "koe.idleUnloadMinutes"
        static let dictationShortcut = "koe.dictationShortcut"
        static let triggerMode = "koe.triggerMode"
        static let doubleTapLock = "koe.doubleTapLock"
        static let pasteLastShortcut = "koe.pasteLastShortcut"
        static let selectedMicUID = "koe.selectedMicUID"
        static let keepMicWarmSeconds = "koe.keepMicWarmSeconds"
        static let minSegmentSeconds = "koe.minSegmentSeconds"
        static let pauseThresholdSeconds = "koe.pauseThresholdSeconds"
        static let wholeDictationOnly = "koe.wholeDictationOnly"
        static let removeFillers = "koe.removeFillers"
        static let collapseStutters = "koe.collapseStutters"
        static let smartPunctuationCleanup = "koe.smartPunctuationCleanup"
        static let spacingMode = "koe.spacingMode"
        static let saveRecordings = "saveRecordings"
    }

    private let defaults = UserDefaults.standard
    private var loading = true

    @Published var engineMode: EngineMode {
        didSet { save(engineMode.rawValue, forKey: Keys.engineMode); scheduleNotify(\.pendingModelNotify) { $0.onModelConfigChanged } }
    }
    @Published var baseModel: BaseModel {
        didSet { save(baseModel.rawValue, forKey: Keys.baseModel); scheduleNotify(\.pendingModelNotify) { $0.onModelConfigChanged } }
    }
    @Published var fuserModel: FuserModel {
        didSet { save(fuserModel.rawValue, forKey: Keys.fuserModel); scheduleNotify(\.pendingModelNotify) { $0.onModelConfigChanged } }
    }
    @Published var ctcVocabBoosting: Bool {
        didSet { save(ctcVocabBoosting, forKey: Keys.ctcVocabBoosting); scheduleNotify(\.pendingModelNotify) { $0.onModelConfigChanged } }
    }
    @Published var idleUnloadMinutes: Int {
        didSet { save(idleUnloadMinutes, forKey: Keys.idleUnloadMinutes); scheduleNotify(\.pendingIdleNotify) { $0.onIdleTimerChanged } }
    }

    @Published var dictationShortcut: KeyBinding {
        didSet { saveJSON(dictationShortcut, forKey: Keys.dictationShortcut); scheduleNotify(\.pendingHotkeyNotify) { $0.onHotkeyConfigChanged } }
    }
    @Published var triggerMode: TriggerMode {
        didSet { save(triggerMode.rawValue, forKey: Keys.triggerMode); scheduleNotify(\.pendingHotkeyNotify) { $0.onHotkeyConfigChanged } }
    }
    @Published var doubleTapLock: Bool {
        didSet { save(doubleTapLock, forKey: Keys.doubleTapLock); scheduleNotify(\.pendingHotkeyNotify) { $0.onHotkeyConfigChanged } }
    }
    @Published var pasteLastShortcut: KeyBinding? {
        didSet { saveOptionalJSON(pasteLastShortcut, forKey: Keys.pasteLastShortcut); scheduleNotify(\.pendingHotkeyNotify) { $0.onHotkeyConfigChanged } }
    }

    @Published var selectedMicUID: String? {
        didSet {
            if let selectedMicUID { defaults.set(selectedMicUID, forKey: Keys.selectedMicUID) }
            else { defaults.removeObject(forKey: Keys.selectedMicUID) }
            scheduleNotify(\.pendingRecorderNotify) { $0.onRecorderConfigChanged }
        }
    }
    @Published var keepMicWarmSeconds: Int {
        didSet { save(keepMicWarmSeconds, forKey: Keys.keepMicWarmSeconds); scheduleNotify(\.pendingRecorderNotify) { $0.onRecorderConfigChanged } }
    }

    @Published var minSegmentSeconds: Double {
        didSet { save(minSegmentSeconds, forKey: Keys.minSegmentSeconds) }
    }
    @Published var pauseThresholdSeconds: Double {
        didSet { save(pauseThresholdSeconds, forKey: Keys.pauseThresholdSeconds) }
    }
    @Published var wholeDictationOnly: Bool {
        didSet { save(wholeDictationOnly, forKey: Keys.wholeDictationOnly) }
    }
    @Published var removeFillers: Bool {
        didSet { save(removeFillers, forKey: Keys.removeFillers) }
    }
    @Published var collapseStutters: Bool {
        didSet { save(collapseStutters, forKey: Keys.collapseStutters) }
    }
    @Published var smartPunctuationCleanup: Bool {
        didSet { save(smartPunctuationCleanup, forKey: Keys.smartPunctuationCleanup) }
    }
    @Published var spacingMode: SpacingMode {
        didSet { save(spacingMode.rawValue, forKey: Keys.spacingMode) }
    }
    @Published var saveRecordings: Bool {
        didSet { save(saveRecordings, forKey: Keys.saveRecordings) }
    }

    var onModelConfigChanged: () -> Void = {}
    var onIdleTimerChanged: () -> Void = {}
    var onHotkeyConfigChanged: () -> Void = {}
    var onRecorderConfigChanged: () -> Void = {}

    private var pendingModelNotify = false
    private var pendingIdleNotify = false
    private var pendingHotkeyNotify = false
    private var pendingRecorderNotify = false

    private func scheduleNotify(
        _ pending: ReferenceWritableKeyPath<AppSettings, Bool>,
        call: @escaping (AppSettings) -> () -> Void
    ) {
        guard !loading, !self[keyPath: pending] else { return }
        self[keyPath: pending] = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self[keyPath: pending] = false
            call(self)()
        }
    }

    private init() {
        engineMode = defaults.string(forKey: Keys.engineMode).flatMap(EngineMode.init) ?? .hybrid
        baseModel = defaults.string(forKey: Keys.baseModel).flatMap(BaseModel.init) ?? .parakeetUnifiedStreaming
        fuserModel = defaults.string(forKey: Keys.fuserModel).flatMap(FuserModel.init) ?? .qwen3_1_7b
        ctcVocabBoosting = defaults.object(forKey: Keys.ctcVocabBoosting) as? Bool ?? true
        idleUnloadMinutes = defaults.object(forKey: Keys.idleUnloadMinutes) as? Int ?? 10

        dictationShortcut = Self.loadJSON(KeyBinding.self, forKey: Keys.dictationShortcut, defaults: defaults) ?? .defaultDictation
        triggerMode = defaults.string(forKey: Keys.triggerMode).flatMap(TriggerMode.init) ?? .hold
        doubleTapLock = defaults.object(forKey: Keys.doubleTapLock) as? Bool ?? true
        if defaults.object(forKey: Keys.pasteLastShortcut) != nil {
            pasteLastShortcut = Self.loadJSON(KeyBinding.self, forKey: Keys.pasteLastShortcut, defaults: defaults)
        } else {
            pasteLastShortcut = .defaultPasteLast
        }

        selectedMicUID = defaults.string(forKey: Keys.selectedMicUID)
        keepMicWarmSeconds = defaults.object(forKey: Keys.keepMicWarmSeconds) as? Int ?? 180

        minSegmentSeconds = defaults.object(forKey: Keys.minSegmentSeconds) as? Double ?? 10.0
        pauseThresholdSeconds = defaults.object(forKey: Keys.pauseThresholdSeconds) as? Double ?? 1.5
        wholeDictationOnly = defaults.object(forKey: Keys.wholeDictationOnly) as? Bool ?? false
        removeFillers = defaults.object(forKey: Keys.removeFillers) as? Bool ?? true
        collapseStutters = defaults.object(forKey: Keys.collapseStutters) as? Bool ?? true
        smartPunctuationCleanup = defaults.object(forKey: Keys.smartPunctuationCleanup) as? Bool ?? true
        spacingMode = defaults.string(forKey: Keys.spacingMode).flatMap(SpacingMode.init) ?? .smart
        saveRecordings = defaults.bool(forKey: Keys.saveRecordings)
        loading = false
    }

    func applyPreset(_ preset: PipelinePreset) {
        loading = true
        engineMode = preset.engineMode
        baseModel = preset.baseModel
        fuserModel = preset.fuserModel
        ctcVocabBoosting = preset.ctcBoosting
        loading = false
        scheduleNotify(\.pendingModelNotify) { $0.onModelConfigChanged }
    }

    func snapshot() -> TuningOptions {
        TuningOptions(
            engineMode: engineMode,
            baseModel: baseModel,
            fuserModel: fuserModel,
            ctcVocabBoosting: ctcVocabBoosting,
            idleUnloadMinutes: idleUnloadMinutes,
            minSegmentSeconds: minSegmentSeconds,
            pauseThresholdSeconds: pauseThresholdSeconds,
            wholeDictationOnly: wholeDictationOnly,
            removeFillers: removeFillers,
            collapseStutters: collapseStutters,
            smartPunctuationCleanup: smartPunctuationCleanup,
            spacingMode: spacingMode
        )
    }

    private func save(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    private func saveJSON<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private func saveOptionalJSON<T: Encodable>(_ value: T?, forKey key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func loadJSON<T: Decodable>(_ type: T.Type, forKey key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Sendable value snapshot of runtime pipeline settings for background actors.
struct TuningOptions: Sendable, Equatable {
    var engineMode: EngineMode = .hybrid
    var baseModel: BaseModel = .parakeetUnifiedStreaming
    var fuserModel: FuserModel = .qwen3_1_7b
    var ctcVocabBoosting: Bool = true
    var idleUnloadMinutes: Int = 10
    var minSegmentSeconds: Double = 10.0
    var pauseThresholdSeconds: Double = 1.5
    var wholeDictationOnly: Bool = false
    var removeFillers: Bool = true
    var collapseStutters: Bool = true
    var smartPunctuationCleanup: Bool = true
    var spacingMode: SpacingMode = .smart
}
