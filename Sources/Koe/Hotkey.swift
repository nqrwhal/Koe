import AppKit
import Carbon.HIToolbox

/// Watches global dictation and Paste Last shortcuts.
/// Supports Hold-to-Talk (with optional double-tap lock), Tap-to-Toggle, Esc cancel,
/// and global shortcut suspension while recording a new binding in Settings.
final class Hotkey {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onLock: () -> Void = {}
    var onCancel: () -> Void = {}
    var onPasteLast: () -> Void = {}

    var binding: KeyBinding = .defaultDictation {
        didSet { resetState() }
    }
    var triggerMode: TriggerMode = .hold {
        didSet { resetState() }
    }
    var doubleTapLock: Bool = true
    var pasteLastBinding: KeyBinding? = .defaultPasteLast
    var isSuspended: Bool = false {
        didSet { if isSuspended { resetState() } }
    }

    private enum State {
        case idle
        case holding(pressedAt: Date)
        case locked
    }

    private var tap: CFMachPort?
    private var state: State = .idle
    private var lastShortTapRelease: Date?

    private static let doubleTapWindow: TimeInterval = 0.35
    private static let shortTapThreshold: TimeInterval = 0.25

    @discardableResult
    func install() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                Unmanaged<Hotkey>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func resetState() {
        state = .idle
        lastShortTapRelease = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard !isSuspended else { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue

        // Esc cancels any active recording immediately.
        if type == .keyDown && keyCode == Int64(kVK_Escape) {
            if case .idle = state { } else {
                resetState()
                onCancel()
                return
            }
        }

        // Check global Paste Last shortcut.
        if type == .keyDown, let pasteLastBinding, matchesKeyChord(pasteLastBinding, keyCode: keyCode, flags: flags) {
            if case .idle = state {
                onPasteLast()
                return
            }
        }

        switch binding.kind {
        case .modifierOnly:
            handleModifierBinding(type: type, keyCode: keyCode, flags: flags)
        case .keyChord:
            handleKeyChordBinding(type: type, event: event, keyCode: keyCode, flags: flags)
        }
    }

    private func handleModifierBinding(type: CGEventType, keyCode: Int64, flags: UInt64) {
        guard let mod = binding.primaryModifier else { return }

        switch type {
        case .flagsChanged:
            let isMatchingKey = mod.matchesKeyCode(keyCode, side: binding.side)
            let isDown = (flags & mod.deviceFlagMask(side: binding.side)) != 0

            // Check that no unexpected other modifiers are held.
            let allowedMask = mod.generalFlagMask | mod.deviceFlagMask(side: binding.side)
                | CGEventFlags.maskAlphaShift.rawValue | CGEventFlags.maskNumericPad.rawValue | 0x20000100
            let allRelevantMods: UInt64 = CGEventFlags.maskCommand.rawValue
                | CGEventFlags.maskAlternate.rawValue
                | CGEventFlags.maskControl.rawValue
                | CGEventFlags.maskShift.rawValue
                | CGEventFlags.maskSecondaryFn.rawValue
            let unexpectedMods = (flags & allRelevantMods) & ~allowedMask

            switch state {
            case .idle:
                if isMatchingKey && isDown && unexpectedMods == 0 {
                    handleShortcutDown()
                }
            case .holding:
                if isMatchingKey && !isDown {
                    handleShortcutUp()
                } else if unexpectedMods != 0 || !isMatchingKey {
                    resetState()
                    onCancel()
                }
            case .locked:
                if isMatchingKey && isDown && unexpectedMods == 0 {
                    state = .idle
                    onRelease()
                }
            }

        case .keyDown:
            // On Fn/Globe shortcuts, macOS sometimes emits auxiliary keyCode 179 for Globe.
            if mod == .fn && keyCode == 179 { return }
            if case .holding = state {
                resetState()
                onCancel()
            }

        default:
            break
        }
    }

    private func handleKeyChordBinding(type: CGEventType, event: CGEvent, keyCode: Int64, flags: UInt64) {
        switch type {
        case .keyDown:
            if eventIsAutoRepeat(event) { return }
            if matchesKeyChord(binding, keyCode: keyCode, flags: flags) {
                switch state {
                case .idle:
                    handleShortcutDown()
                case .locked:
                    state = .idle
                    onRelease()
                case .holding:
                    break
                }
            }
        case .keyUp:
            if let targetCode = binding.keyCode, keyCode == targetCode {
                if case .holding = state {
                    handleShortcutUp()
                }
            }
        case .flagsChanged:
            // If user released a required modifier while holding a chord, finish cleanly.
            if case .holding = state, !hasRequiredModifiers(binding, flags: flags) {
                handleShortcutUp()
            }
        default:
            break
        }
    }

    private func handleShortcutDown() {
        let now = Date()
        if triggerMode == .tapToToggle {
            lastShortTapRelease = nil
            state = .locked
            onPress()
            onLock()
            return
        }

        if doubleTapLock, let prev = lastShortTapRelease, now.timeIntervalSince(prev) <= Self.doubleTapWindow {
            lastShortTapRelease = nil
            state = .locked
            onPress()
            onLock()
            return
        }

        state = .holding(pressedAt: now)
        onPress()
    }

    private func handleShortcutUp() {
        guard case .holding(let pressedAt) = state else { return }
        let held = Date().timeIntervalSince(pressedAt)
        state = .idle
        if held < Self.shortTapThreshold {
            lastShortTapRelease = doubleTapLock ? Date() : nil
            onCancel()
        } else {
            lastShortTapRelease = nil
            onRelease()
        }
    }

    private func matchesKeyChord(_ chord: KeyBinding, keyCode: Int64, flags: UInt64) -> Bool {
        guard chord.kind == .keyChord, let targetCode = chord.keyCode, keyCode == targetCode else { return false }
        return hasRequiredModifiers(chord, flags: flags)
    }

    private func hasRequiredModifiers(_ chord: KeyBinding, flags: UInt64) -> Bool {
        let relevant: UInt64 = CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskShift.rawValue
        var required: UInt64 = 0
        for mod in chord.modifiers {
            if mod != .fn { required |= mod.generalFlagMask }
        }
        return (flags & relevant) == required
    }

    private func eventIsAutoRepeat(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    }
}
