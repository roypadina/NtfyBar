import AppKit
import NtfyBarCore

/// App-wide wiring: the Core engine plus everything that needs AppKit. One shared instance,
/// created on first use and started by the app delegate.
@MainActor
final class AppModel {
    static let shared = AppModel()

    let engine: Engine
    let notifier = Notifier()
    private(set) lazy var performer = EffectPerformer(model: self)
    let isTestMode = ProcessInfo.processInfo.environment["NTFYBAR_TEST"] == "1"
    private var started = false

    private init() {
        do {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
            engine = try Engine(bundledPlugins: Bundle.main.resourceURL?.appendingPathComponent("BundledPlugins"), appVersion: version)
        } catch {
            let alert = NSAlert()
            alert.messageText = "NtfyBar can't open its data folder"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            exit(1)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        notifier.setUp(model: self)
        engine.onEffects = { [weak self] in self?.performer.perform($0) }
        engine.onCopy = { [weak self] in self?.performer.copy($0) }
        engine.onOpen = { [weak self] in self?.performer.open($0.absoluteString) }
        engine.start()
        engine.startNetworkMonitoring()
        engine.startWatchingFiles()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.reconnectAll() }
        }
        registerLoginItemOnce()
    }

    func pause(until date: Date?) {
        try? engine.update { $0.pausedUntil = date }
    }

    func label(for topicId: UUID) -> String {
        engine.config.topic(topicId)?.displayLabel ?? "Removed topic"
    }

    /// "label · title" for menus; never the raw topic.
    func recentTitle(_ m: Message) -> String {
        let text = (m.title?.isEmpty == false ? m.title! : m.body).replacingOccurrences(of: "\n", with: " ")
        let short = text.count > 60 ? String(text.prefix(57)) + "…" : text
        return "\(label(for: m.topicId)) · \(short)"
    }

    func showRecent(_ m: Message) {
        engine.markRead(m)
        let settings = engine.config.topic(m.topicId)?.popup ?? PopupSettings()
        performer.showPopup(PopupRequest(message: m, label: label(for: m.topicId), settings: settings), playSound: false)
    }

    /// "Edit rules file…": write the current rules first so there is always a file to edit.
    func openRulesFile() {
        if !FileManager.default.fileExists(atPath: engine.store.rulesURL.path) {
            try? engine.store.saveRules(engine.rules)
        }
        NSWorkspace.shared.open(engine.store.rulesURL)
    }

    /// A plugin popup button: the plugin answers with close or a new popup (same panel).
    func pluginPopupAction(_ buttonId: String, state: PopupState) {
        let c = state.content
        guard let ref = c.plugin else { PopupPanel.dismiss(state); return }
        switch engine.pluginPopupAction(ref, buttonId: buttonId, topicId: c.topicId, messageId: c.messageId) {
        case .close:
            PopupPanel.dismiss(state)
        case let .replace(spec):
            guard let topicId = c.topicId, let messageId = c.messageId else { PopupPanel.dismiss(state); return }
            let req = PluginPopupRequest(pluginId: ref.pluginId, pluginName: engine.pluginName(ref.pluginId), spec: spec,
                                         topicId: topicId, messageId: messageId, label: label(for: topicId),
                                         defaults: engine.config.topic(topicId)?.popup ?? PopupSettings())
            var next = req.content
            next.key = c.key
            state.content = next
            PopupPanel.relayout()
        }
    }

    /// Registered once, and only for the installed copy: a dev build in dist/ must never become
    /// the login item.
    private func registerLoginItemOnce() {
        let config = engine.config
        guard !isTestMode, !config.didRegisterLoginItem, Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        do {
            try LoginItemManager().setEnabled(config.launchAtLogin)
        } catch {
            Log.app.error("login item: \(error.localizedDescription, privacy: .public)")
        }
        try? engine.update { $0.didRegisterLoginItem = true }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var activity: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Single instance: a second copy (e.g. launched again from /Applications) just leaves.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        ensureEditMenu()
        // Live subscriptions must not be napped.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Live ntfy subscriptions")
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    /// An accessory app only gets ⌘C/⌘V/⌘X/⌘A in text fields when the main menu has these items.
    private func ensureEditMenu() {
        let main = NSApp.mainMenu ?? NSMenu()
        guard !main.items.contains(where: { $0.submenu?.items.contains { $0.action == #selector(NSText.paste(_:)) } == true }) else { return }
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        main.addItem(item)
        NSApp.mainMenu = main
    }
}
