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
        keepFront(window)
    }

    /// shortcut: ~0.5 s after the .accessory → .regular switch macOS hands activation back to the previous app (traced in
    /// PullPing: Settings behind Ghostex, no click). Take it back once unless the user clicked elsewhere meanwhile; drop when macOS stops.
    /// Limit: a keyboard switch (⌘-Tab, a launcher hotkey) within the 1.5 s is pulled back once. nil = Sparkle's update window.
    func keepFront(_ window: NSWindow?) {
        var clicked = false, done = false
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in clicked = true }
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard !clicked, !done, NSApp.activationPolicy() == .regular, window?.isVisible ?? true else { return }
                done = true
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            monitor.map(NSEvent.removeMonitor)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func becomeRegular() {
        SupportPanel.interrupt()  // every window opens through here: a Ko-fi card still open counts as "Ask me in 2 weeks"
        NSApp.setActivationPolicy(.regular)
        // Forceful: a user action, and on macOS 14+ the front app can refuse the activate() request (window opens behind).
        NSApp.activate(ignoringOtherApps: true)
    }

    private func windowWillClose(_ closing: NSWindow?) {
        guard closing?.canBecomeMain == true else { return }
        let others = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain }
        if !others { NSApp.setActivationPolicy(.accessory) }
    }
}
