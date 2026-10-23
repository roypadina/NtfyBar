import AppKit
import NtfyBarCore
import UserNotifications

/// macOS notifications. Only works from a bundled app — `swift run` has no bundle identifier and
/// UNUserNotificationCenter would crash, so everything here is a no-op there.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let messageCategory = "ntfybar.message"
    static let summaryCategory = "ntfybar.summary"

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private weak var model: AppModel?

    var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func setUp(model: AppModel) {
        self.model = model
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let copy = UNNotificationAction(identifier: "copy", title: "Copy", options: [])
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.messageCategory, actions: [copy, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.summaryCategory, actions: [], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error { Log.app.error("notification permission: \(error.localizedDescription, privacy: .public)") }
            Task { @MainActor in self.refreshAuthorization() }
        }
    }

    func refreshAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                self.authorization = status
                Log.app.info("notification authorization: \(status.rawValue, privacy: .public)")
            }
        }
    }

    func post(_ m: Message, label: String, silent: Bool) {
        guard isAvailable else { return }
        let text = NotificationText.message(m, label: label)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.subtitle = text.subtitle
        content.body = text.body
        content.categoryIdentifier = Self.messageCategory
        content.threadIdentifier = m.topicId.uuidString
        content.userInfo = ["topicId": m.topicId.uuidString, "id": m.ntfy.id]
        // ntfy semantics: min/low priority make no sound.
        content.sound = silent || m.priority <= 2 ? nil : .default
        add(UNNotificationRequest(identifier: m.id, content: content, trigger: nil))
    }

    /// App-level notices (catch-up summary, flood notice, failed command).
    func post(_ text: NotificationText, category: String?) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.subtitle = text.subtitle
        content.body = text.body
        if let category { content.categoryIdentifier = category }
        add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.app.error("notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        let topicText = info["topicId"] as? String
        let id = info["id"] as? String
        Task { @MainActor in
            self.handle(action: action, category: category, topicId: topicText.flatMap(UUID.init(uuidString:)), id: id)
            completionHandler()
        }
    }

    private func handle(action: String, category: String, topicId: UUID?, id: String?) {
        guard let model else { return }
        if category == Self.summaryCategory {
            HistoryWindow.show(model: model)
            return
        }
        guard let topicId, let id, let m = model.engine.history.message(topicId: topicId, id: id) else { return }
        model.engine.markRead(m)
        switch action {
        case "copy":
            model.performer.copy(m.body)
        case "open":
            model.performer.open(m.ntfy.click)
        default:  // clicked the banner itself
            if SafeOpen.url(m.ntfy.click) != nil {
                model.performer.open(m.ntfy.click)
            } else {
                model.showRecent(m)
            }
        }
    }
}
