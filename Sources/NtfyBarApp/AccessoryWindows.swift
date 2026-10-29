import AppKit

/// NtfyBar has no Dock icon, so a window opened from the menu bar is easy to lose behind other apps (MBX-15).
/// While a real window is open the app is `.regular` (Dock icon, Cmd-Tab, menu bar); it goes back to
/// `.accessory` when the last one closes. One close observer instead of a delegate: the SwiftUI Settings
/// window owns its delegate. Popup panels can't become main, so they don't count.
@MainActor
final class AccessoryWindows {
    static let shared = AccessoryWindows()

    private init() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.windowWillClose(note.object as? NSWindow) }
        }
    }

    func show(_ window: NSWindow) {
        becomeRegular()
        window.makeKeyAndOrderFront(nil)
    }

    func becomeRegular() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    private func windowWillClose(_ closing: NSWindow?) {
        guard closing?.canBecomeMain == true else { return }
        let others = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain }
        if !others { NSApp.setActivationPolicy(.accessory) }
    }
}
