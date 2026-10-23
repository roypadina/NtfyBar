import Foundation

/// Everything NtfyBar shows in a macOS notification, built from label + message only — never the
/// raw topic or the server URL.
public struct NotificationText: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var body: String

    public init(title: String, subtitle: String = "", body: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }

    public static func message(_ m: Message, label: String) -> NotificationText {
        let emoji = Emoji.prefix(for: m.tags)
        let body = m.body.count > 2000 ? String(m.body.prefix(2000)) + "…" : m.body
        if let title = m.title, !title.isEmpty {
            return NotificationText(title: emoji + title, subtitle: label, body: body)
        }
        return NotificationText(title: emoji + label, subtitle: "", body: body)
    }

    public static func catchUp(label: String, count: Int) -> NotificationText {
        NotificationText(title: "\(count) message\(count == 1 ? "" : "s") while away · \(label)", subtitle: "",
                         body: "Open NtfyBar's History to read them.")
    }

    public static func flood(label: String) -> NotificationText {
        NotificationText(title: "Lots of messages · \(label)", subtitle: "",
                         body: "NtfyBar is holding further alerts for this topic until it calms down. They're all in History.")
    }
}
