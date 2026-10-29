import AppKit

/// Watches Right Command globally. Holding it alone means "dictate";
/// pressing any other key or modifier while it's held cancels, so ⌘-shortcuts still work.
final class Hotkey {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onCancel: () -> Void = {}

    private static let rightCommandKeycode: Int64 = 54
    private static let rightCommandFlag: UInt64 = 0x10  // NX_DEVICERCMDKEYMASK
    private var tap: CFMachPort?
    private var held = false

    func install() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
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

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let isRightCommand = event.getIntegerValueField(.keyboardEventKeycode) == Self.rightCommandKeycode
            let rightCommandDown = event.flags.rawValue & Self.rightCommandFlag != 0
            if isRightCommand && rightCommandDown && !held {
                held = true
                onPress()
            } else if isRightCommand && !rightCommandDown && held {
                held = false
                onRelease()
            } else if held {
                held = false
                onCancel()
            }
        case .keyDown:
            if held {
                held = false
                onCancel()
            }
        default:
            break
        }
    }
}
