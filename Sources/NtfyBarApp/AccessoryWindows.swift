import AppKit
import OSLog

/// NtfyBar has no Dock icon, so a window opened from the menu bar is easy to lose behind other apps (MBX-15).
/// While a real window is open the app is `.regular` (Dock icon, Cmd-Tab, menu bar); it goes back to
/// `.accessory` when the last one closes. One close observer instead of a delegate: the SwiftUI Settings
/// window owns its delegate. Popup panels can't become main, so they don't count.
@MainActor
final class AccessoryWindows {
    static let shared = AccessoryWindows()
    static let log = Logger(subsystem: "com.padina.ntfybar", category: "activation")

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

    /// shortcut: ~0.5 s after the .accessory → .regular switch macOS hands activation back to the previous app (traced:
    /// Settings behind Ghostex, no click). Take it back once, within 1.5 s of the show, and only if there was no click or key
    /// press anywhere since (asked of the window server when activation goes, so no event monitor can lose the race: a click in
    /// Edge stole focus back, traced); drop when macOS stops. nil = Sparkle's update window.
    func keepFront(_ window: NSWindow?) {
        let shown = Date()
        var done = false
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let elapsed = Date().timeIntervalSince(shown)
                let input = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
                    .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
                guard !done, elapsed < 1.5, input > elapsed, NSApp.activationPolicy() == .regular, window?.isVisible ?? true else { return }
                done = true
                Self.log.notice("keepFront: took activation back from \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-", privacy: .public) \(Int(elapsed * 1000)) ms after showing \(window?.title ?? "the update window", privacy: .public)")
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NotificationCenter.default.removeObserver(observer) }
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
