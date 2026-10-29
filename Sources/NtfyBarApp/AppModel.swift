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
    private var resumeTask: Task<Void, Never>?

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
        if !engine.migrationNotes.isEmpty {
            let n = engine.migrationNotes.filter { $0.hasPrefix("absorbed rule") }.count  // one such note per absorbed rule
            notifier.post(NotificationText(title: "NtfyBar 1.4: \(n) rule\(n == 1 ? "" : "s") became topic plans",
                                           body: "Backups: config.pre-1.4.json, rules.pre-1.4.json"), category: nil)
        }
        engine.onEffects = { [weak self] in self?.performer.perform($0) }
        engine.onCopy = { [weak self] in self?.performer.copy($0) }
        engine.onOpen = { [weak self] in self?.performer.open($0.absoluteString) }
        engine.start()
        engine.startNetworkMonitoring()
        engine.startWatchingFiles()
        scheduleResume()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.reconnectAll() }
        }
    }

    func pause(until date: Date?) {
        try? engine.update { $0.pausedUntil = date }
        scheduleResume()
    }

    /// A timed pause ends without a state change; clear it then, so the status icon (which watches the config) goes back to the bell.
    /// Called on every change of `pausedUntil` (menu, reload, external edit). The config file stores whole seconds, so the
    /// check is "expired", not "unchanged", and the extra second covers that rounding.
    func scheduleResume() {
        resumeTask?.cancel()
        guard let until = engine.config.pausedUntil, until != .distantFuture, until > Date() else { return }
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow + 1))
            guard !Task.isCancelled, let self else { return }
            self.engine.reloadIfChangedOnDisk()  // don't overwrite an external edit the 2 s poll hasn't read yet
            guard let p = self.engine.config.pausedUntil, p != .distantFuture, p <= Date() else { return }
            try? self.engine.update { $0.pausedUntil = nil }
        }
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
        let settings = engine.config.topic(m.topicId).map { $0.popup.settings(timeoutSec: $0.band(m.priority).timeoutSec) } ?? PopupSettings()
        performer.showPopup(PopupRequest(message: m, label: label(for: m.topicId), settings: settings), playSound: false)
    }

    // MARK: publish

    /// The topic of the last send, while it exists and is enabled.
    var lastPublishTopic: TopicConfig? {
        engine.config.publish.lastTopicId.flatMap { engine.config.topic($0) }.flatMap { $0.enabled ? $0 : nil }
    }

    var clipboardIsEmpty: Bool { NSPasteboard.general.pasteboardItems?.isEmpty ?? true }

    /// Files on the pasteboard (one message each), else a picture as PNG, else text.
    static func clipboardItems(_ pb: NSPasteboard = .general) -> [Outgoing] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(Outgoing.file)
        }
        if let png = pb.data(forType: .png)
            ?? pb.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) {
            return [.image(png)]
        }
        if let text = pb.string(forType: .string), !text.isEmpty { return [.text(text)] }
        return []
    }

    /// Menu "Send Clipboard to …": to the last topic; none yet → the Publish window.
    func sendClipboard() {
        guard let topic = lastPublishTopic else { PublishWindow.show(model: self); return }
        let items = Self.clipboardItems()
        guard !items.isEmpty else {
            notifier.post(NotificationText(title: "Couldn't send: the clipboard is empty", body: ""), category: nil)
            return
        }
        Task {
            let result = await send(items, topicId: topic.id, title: engine.config.publish.title, tags: [], priority: 3)
            notifier.post(NotificationText(title: result.text, body: ""), category: nil)
        }
    }

    /// A user-initiated send, described for a notification or the window's status line:
    /// "Sent to “Clipboard” · 2 files" or "Couldn't send: <reason>".
    func send(_ items: [Outgoing], topicId: UUID, title: String, tags: [String], priority: Int) async -> (ok: Bool, text: String) {
        let result: (ok: Bool, text: String)
        do {
            try await engine.send(items, topicId: topicId, title: title, tags: tags, priority: priority)
            let files = items.filter { if case .text = $0 { false } else { true } }.count
            result = (true, "Sent to “\(label(for: topicId))”" + (files == 0 ? "" : " · \(files) file\(files == 1 ? "" : "s")"))
        } catch {
            result = (false, "Couldn't send: " + ((error as? PublishError)?.reason ?? error.localizedDescription))
        }
        if isTestMode { print("publish \(result.text)"); fflush(stdout) }
        return result
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
                                         defaults: engine.config.topic(topicId)?.popup.settings(timeoutSec: 0) ?? PopupSettings())
            var next = req.content
            next.key = c.key
            state.content = next
            PopupPanel.relayout()
        }
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

    /// Opening the app again (Finder, Raycast) while its icon is hidden by the notch or a full menu bar.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsOpener.open() }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        ensureEditMenu()
        // Live subscriptions must not be napped.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Live ntfy subscriptions")
        MainActor.assumeIsolated {
            AppModel.shared.start()
            if !AppModel.shared.isTestMode { WelcomeWindow.showOnce() }
        }
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
