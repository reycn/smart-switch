import AppKit
import CoreGraphics

/// Session-level CGEventTap. Consumes ⌘` (keycode 50) → `onSwitch`; observes ⌘Tab (keycode 48,
/// passed through) → `onCmdTab` so the next activation can be attributed to the user.
/// Needs Accessibility; polls until granted, then installs the tap.
final class HotkeyTap {
    private let onSwitch: () -> Void
    private let onCmdTab: () -> Void
    private var port: CFMachPort?
    private var retry: Timer?

    init(onSwitch: @escaping () -> Void, onCmdTab: @escaping () -> Void) {
        self.onSwitch = onSwitch
        self.onCmdTab = onCmdTab
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    /// No system alert here: when not trusted, the app opens its Settings window, where
    /// PermissionFlow guides the user through System Settings, and we poll until granted.
    func start() {
        if Self.trusted {
            install()
        } else {
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard let self, Self.trusted else { return }
                t.invalidate()
                self.install()
            }
        }
    }

    private func install() {
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let port = tap.port { CGEvent.tapEnable(tap: port, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            switch keycode {
            case 50 where mods == .maskCommand:
                DispatchQueue.main.async { tap.onSwitch() }
                return nil // swallow so the frontmost app doesn't cycle its own windows
            case 48 where mods.contains(.maskCommand) && mods.isDisjoint(with: [.maskControl, .maskAlternate]):
                DispatchQueue.main.async { tap.onCmdTab() }
                return Unmanaged.passUnretained(event)
            default:
                return Unmanaged.passUnretained(event)
            }
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }
}
