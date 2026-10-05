import Cocoa

final class KeyMonitor {
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnPressed = false

    func start() -> Bool {
        if eventTap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func stop() {
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        runLoopSource = nil; eventTap = nil; fnPressed = false
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if fnPressed { fnPressed = false; DispatchQueue.main.async { [weak self] in self?.onFnUp?() } }
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Ignore function-key flags (e.g. F5), which can also contain maskSecondaryFn.
        guard event.getIntegerValueField(.keyboardEventKeycode) == 63 else { return Unmanaged.passUnretained(event) }
        let down = event.flags.contains(.maskSecondaryFn)
        if down && !fnPressed {
            let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            guard event.flags.intersection(modifiers).isEmpty else { return Unmanaged.passUnretained(event) }
            fnPressed = true
            DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
            return nil
        }
        if !down && fnPressed {
            fnPressed = false
            DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}
