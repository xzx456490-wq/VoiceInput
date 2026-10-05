import AppKit
import Carbon

final class TextInjector {
    struct Target {
        let pid: pid_t
        let element: AXUIElement?
    }
    static func captureTarget() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &value)
        let element = value.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        return Target(pid: app.processIdentifier, element: element)
    }
    private static func matches(_ target: Target) -> Bool {
        guard let now = captureTarget(), now.pid == target.pid else { return false }
        if let expected = target.element, let actual = now.element { return CFEqual(expected, actual) }
        return target.element == nil && now.element == nil
    }
    static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
    }
    func inject(_ text: String, into target: Target?, completion: @escaping (Bool) -> Void) {
        guard !text.isEmpty, AXIsProcessTrusted(), let target, Self.matches(target) else { completion(false); return }
        let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let temporary = isASCII(original) ? nil : findASCII()
        if let temporary { TISSelectInputSource(temporary) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard Self.matches(target) else {
                self.restoreInput(original, temporary: temporary); completion(false); return
            }
            let board = NSPasteboard.general
            let saved = Self.snapshot(board)
            board.clearContents(); board.setString(text, forType: .string)
            let ownedCount = board.changeCount
            let source = CGEventSource(stateID: .combinedSessionState)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                board.clearContents(); board.writeObjects(saved)
                self.restoreInput(original, temporary: temporary); completion(false); return
            }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.post(tap: .cgAnnotatedSessionEventTap); up.post(tap: .cgAnnotatedSessionEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.restoreInput(original, temporary: temporary)
                // Do not overwrite anything the user copied while the paste was settling.
                if board.changeCount == ownedCount { board.clearContents(); board.writeObjects(saved) }
                completion(true)
            }
        }
    }
    private func restoreInput(_ original: TISInputSource, temporary: TISInputSource?) {
        guard let temporary else { return }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        if CFEqual(current, temporary) { TISSelectInputSource(original) }
    }
    private func isASCII(_ source: TISInputSource) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }
    private func findASCII() -> TISInputSource? {
        let criteria = [kTISPropertyInputSourceIsASCIICapable: true, kTISPropertyInputSourceIsEnabled: true] as CFDictionary
        guard let sources = TISCreateInputSourceList(criteria, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return sources.first { source in
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
            let name = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
            return name == "com.apple.keylayout.ABC" || name == "com.apple.keylayout.US"
        } ?? sources.first
    }
}
