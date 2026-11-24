import AppKit
import ApplicationServices

/// Types text into the focused app by pasting it, then puts the user's clipboard back.
enum Paster {
    static func paste(_ text: String, spacing: SpacingMode = .smart) {
        let prepared = prepareText(text, spacing: spacing)
        guard !prepared.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(prepared, forType: .string)
        // Tells clipboard managers not to record this temporary entry.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ourChange = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: keyDown)  // V
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    static func prepareText(_ text: String, spacing: SpacingMode) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        switch spacing {
        case .none:
            return trimmed
        case .trailingSpace:
            return trimmed + " "
        case .smart:
            if let charBefore = characterBeforeCursor() {
                if let c = charBefore, !c.isWhitespace, !"([{\"'/`\n\r".contains(c) {
                    return " " + trimmed
                }
                return trimmed
            }
            // Target app doesn't expose AX text range (e.g. some terminals/Electron views):
            // fall back to trailing space so consecutive dictations don't run together.
            return trimmed + " "
        }
    }

    /// Returns `Optional<Character?>`: `.none` means AX text inspection is unavailable;
    /// `.some(nil)` means cursor is at offset 0 (start of field); `.some(char)` is the preceding char.
    private static func characterBeforeCursor() -> Character?? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef
        else { return nil }
        let focused = focusedRef as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef
        else { return nil }
        let axRangeVal = rangeRef as! AXValue
        guard AXValueGetType(axRangeVal) == .cfRange else { return nil }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axRangeVal, .cfRange, &range) else { return nil }
        if range.location <= 0 { return .some(nil) }

        var prevRange = CFRange(location: range.location - 1, length: 1)
        guard let prevRangeVal = AXValueCreate(.cfRange, &prevRange) else { return nil }
        var textRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused,
            kAXStringForRangeParameterizedAttribute as CFString,
            prevRangeVal,
            &textRef
        ) == .success,
              let str = textRef as? String
        else { return nil }
        return .some(str.last)
    }
}
