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
                model.notifier.postSummary(label: label, count: count)
            case let .popup(request):
                showPopup(request, playSound: false)
            case let .summaryPopup(topicId, label, count):
                showSummaryPopup(topicId: topicId, label: label, count: count)
            case let .copy(text):
                copy(text)
            case let .playSound(name):
                NSSound(named: NSSound.Name(name))?.play()
            case let .openURL(url):
                open(url.absoluteString)
            case .runCommand, .runShortcut, .publish:
                // shortcut: M1 — commands, shortcuts and publishing arrive in M2a.
                Log.app.info("effect not yet supported in this build")
            }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func open(_ text: String?) {
        guard let url = SafeOpen.url(text) else {
            if text?.isEmpty == false { Log.app.error("refused to open a non-http(s) URL") }
            return
        }
        NSWorkspace.shared.open(url)
    }

    func showPopup(_ request: PopupRequest, playSound: Bool) {
        // shortcut: M1 — the native popup arrives in M2b; until then a notification stands in.
        model.notifier.post(request.message, label: request.label, silent: !playSound)
    }

    func showSummaryPopup(topicId: UUID, label: String, count: Int) {
        Log.app.info("flood summary popup (\(count, privacy: .public))")
    }

    static func describe(_ e: Effect) -> String {
        switch e {
        case let .notify(m, _): "notify \(m.ntfy.id)"
        case let .popup(r): "popup \(r.message.ntfy.id)"
        case let .summaryPopup(_, _, n): "summaryPopup \(n)"
        case let .summaryNotification(_, _, n): "summaryNotification \(n)"
        case .copy: "copy"
        case let .playSound(s): "sound \(s)"
        case let .runCommand(_, m, _): "command \(m.ntfy.id)"
        case let .runShortcut(name, _): "shortcut \(name)"
        case .openURL: "openURL"
        case .publish: "publish"
        }
    }
}
