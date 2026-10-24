import AppKit
import NtfyBarCore

/// Carries out the Dispatcher's effects. Every URL goes through SafeOpen (http/https only).
@MainActor
final class EffectPerformer {
    private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func perform(_ effects: [Effect]) {
        // When the app plays its own sound (popup/rule), the notification stays silent.
        let ownSound = effects.contains { if case .playSound = $0 { true } else { false } }
        for effect in effects {
            if model.isTestMode { print("effect \(Self.describe(effect))"); fflush(stdout) }
            switch effect {
            case let .notify(m, label):
                model.notifier.post(m, label: label, silent: ownSound)
            case let .summaryNotification(_, label, count):
                model.notifier.post(NotificationText.catchUp(label: label, count: count), category: Notifier.summaryCategory)
            case let .floodNotification(_, label):
                model.notifier.post(NotificationText.flood(label: label), category: Notifier.summaryCategory)
            case let .popup(request):
                showPopup(request, playSound: false)
            case let .pluginPopup(request):
                PopupPanel.show(request.content) { [weak self] button, state in self?.handle(button, in: state) }
            case let .summaryPopup(topicId, label, count):
                showSummaryPopup(topicId: topicId, label: label, count: count)
            case let .copy(text):
                copy(text)
            case let .attachment(m, copyAfterSec):
                let started = Date()
                Task { @MainActor in
                    do {
                        let file = try await attachmentFile(m)
                        guard let gap = copyAfterSec else { return }
                        let wait = gap - Date().timeIntervalSince(started)
                        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                        copyFile(file, type: m.ntfy.attachment?.type)
                    } catch { Log.app.error("attachment: \(error.localizedDescription, privacy: .public)") }
                }
            case let .playSound(name):
                NSSound(named: NSSound.Name(name))?.play()
            case let .openURL(url):
                open(url.absoluteString)
            case let .runCommand(settings, m, label):
                model.engine.runCommand(settings, message: m) { [weak model] reason in
                    model?.notifier.post(NotificationText(title: "Command failed · \(label)", subtitle: "", body: reason), category: nil)
                }
            case let .runShortcut(name, m):
                model.engine.runShortcut(name: name, message: m) { [weak model] reason in
                    model?.notifier.post(NotificationText(title: "Shortcut failed", subtitle: "", body: reason), category: nil)
                }
            case let .publish(request):
                Task { try? await model.engine.publish(request, rateKey: "rules") }
            }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// message id -> saved file, so Copy file after Download (or an auto-download) doesn't fetch twice.
    private var savedFiles: [String: URL] = [:]

    private func attachmentFile(_ m: Message) async throws -> URL {
        if let url = savedFiles[m.id], FileManager.default.fileExists(atPath: url.path) { return url }
        guard let a = m.ntfy.attachment else { throw AttachmentFile.Failure(errorDescription: "no attachment") }
        let url = try await AttachmentFile.download(a, server: model.engine.config.topic(m.topicId).flatMap { model.engine.config.server($0.serverId) })
        savedFiles[m.id] = url
        return url
    }

    /// Images paste as a picture anywhere; every other type pastes as a file in Finder.
    func copyFile(_ file: URL, type: String?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if type?.lowercased().hasPrefix("image/") == true, let tiff = NSImage(contentsOf: file)?.tiffRepresentation {
            let item = NSPasteboardItem()
            item.setData(tiff, forType: .tiff)
            if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
            pb.writeObjects([item])
        } else {
            pb.writeObjects([file as NSURL])
        }
    }

    func open(_ text: String?) {
        guard let url = SafeOpen.url(text) else {
            if text?.isEmpty == false { Log.app.error("refused to open a non-http(s) URL") }
            return
        }
        NSWorkspace.shared.open(url)
    }

    func showPopup(_ request: PopupRequest, playSound: Bool) {
        let content = PopupContent.forMessage(request)
        if playSound, let sound = request.settings.sound(forPriority: request.message.priority) {
            NSSound(named: NSSound.Name(sound))?.play()
        }
        PopupPanel.show(content) { [weak self] button, state in self?.handle(button, in: state) }
    }

    func showSummaryPopup(topicId: UUID, label: String, count: Int) {
        PopupPanel.show(PopupContent.flood(topicId: topicId, label: label, count: count)) { [weak self] button, state in
            self?.handle(button, in: state)
        }
    }

    /// One handler for every popup button. Opening, http actions and dismissing mark the message read.
    func handle(_ button: PopupContent.Button, in state: PopupState) {
        let content = state.content
        let markRead = { [model] in
            if let topicId = content.topicId, let id = content.messageId,
               let m = model.engine.history.message(topicId: topicId, id: id) {
                model.engine.markRead(m)
            }
        }
        switch button.action {
        case let .open(url):
            open(url.absoluteString)
            markRead()
            PopupPanel.dismiss(state)
        case let .copy(text):
            copy(text)
            flash(button.id, in: state)
        case let .attachment(copyIt):
            guard let topicId = content.topicId, let id = content.messageId,
                  let m = model.engine.history.message(topicId: topicId, id: id) else { state.failed = button.id; return }
            Task { @MainActor in
                do {
                    let file = try await attachmentFile(m)
                    if copyIt { copyFile(file, type: m.ntfy.attachment?.type) }
                    flash(button.id, in: state)
                } catch {
                    Log.app.error("attachment: \(error.localizedDescription, privacy: .public)")
                    state.failed = button.id
                }
            }
        case .attachmentFolder:
            let saved = content.topicId.flatMap { t in content.messageId.map { savedFiles["\(t.uuidString)/\($0)"] } } ?? nil
            switch AttachmentFile.folderAction(saved: saved) {
            case let .reveal(file): NSWorkspace.shared.activateFileViewerSelecting([file])
            case let .openFolder(dir):
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
            }
        case .dismiss:
            markRead()
            PopupPanel.dismiss(state)
        case .showHistory:
            HistoryWindow.show(model: model)
            PopupPanel.dismiss(state)
        case let .http(action):
            Task { @MainActor in
                let ok = await HTTPAction.perform(action, session: Self.actionSession)
                if ok {
                    markRead()
                    if button.clears { PopupPanel.dismiss(state) } else { flash(button.id, in: state) }
                } else {
                    state.failed = button.id
                }
            }
        case let .plugin(buttonId):
            model.pluginPopupAction(buttonId, state: state)
        }
    }

    private func flash(_ id: String, in state: PopupState) {
        state.flashed = id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if state.flashed == id { state.flashed = nil }
        }
    }

    /// ntfy `http` action buttons: no cookies, no cache, never the server's credentials.
    static let actionSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    static func describe(_ e: Effect) -> String {
        switch e {
        case let .notify(m, _): "notify \(m.ntfy.id)"
        case let .popup(r): "popup \(r.message.ntfy.id)"
        case let .pluginPopup(r): "pluginPopup \(r.pluginId)"
        case let .summaryPopup(_, _, n): "summaryPopup \(n)"
        case let .summaryNotification(_, _, n): "summaryNotification \(n)"
        case .floodNotification: "floodNotification"
        case .copy: "copy"
        case .attachment: "attachment"
        case let .playSound(s): "sound \(s)"
        case let .runCommand(_, m, _): "command \(m.ntfy.id)"
        case let .runShortcut(name, _): "shortcut \(name)"
        case .openURL: "openURL"
        case .publish: "publish"
        }
    }
}
