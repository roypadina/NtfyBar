import Foundation

/// What a popup shows, built from a message (or, in M3, a plugin's declarative spec). The app's
/// popup view renders exactly this; all decisions about buttons live here so they're testable.
public struct PopupContent: Equatable, Sendable {
    public enum Accent: String, Codable, Sendable { case info, success, warning, critical }

    public struct KV: Equatable, Sendable {
        public var key: String
        public var value: String

        public init(_ key: String, _ value: String) {
            self.key = key
            self.value = value
        }
    }

    public enum Block: Equatable, Sendable {
        case text(String, markdown: Bool)
        case keyValue([KV])
        case progress(Double, label: String?)
        case badge(String)
    }

    public struct Button: Equatable, Sendable, Identifiable {
        public enum Action: Equatable, Sendable {
            case open(URL)
            case http(NtfyAction)
            case copy(String)
            case attachment(copy: Bool)
            case dismiss
            case showHistory
            case plugin(String)  // button id sent to the plugin's onPopupAction
        }

        public var id: String
        public var label: String
        public var style: PopupButton.Style
        public var action: Action
        /// ntfy `clear`: dismiss the popup after the action succeeds.
        public var clears: Bool
        /// Set for buttons defined by the message sender: shown with a glyph and the target host,
        /// so they can't pass for NtfyBar's own buttons.
        public var senderHost: String?

        public init(id: String, label: String, style: PopupButton.Style = .default, action: Action, clears: Bool = false,
                    senderHost: String? = nil) {
            self.id = id
            self.label = label
            self.style = style
            self.action = action
            self.clears = clears
            self.senderHost = senderHost
        }
    }

    public var key: String
    public var header: String
    public var date: Date?
    public var priority: Int?
    public var icon: String
    public var accent: Accent
    public var title: String
    public var blocks: [Block]
    public var tags: [String]
    public var attachment: (label: String, url: URL?)?
    public var buttons: [Button]
    /// 0 = stays until dismissed.
    public var timeoutSec: Int
    public var level: PopupSettings.Level
    public var position: PopupSettings.Position
    public var topicId: UUID?
    public var messageId: String?
    /// What ⌘C copies.
    public var copyText: String?
    /// Set for plugin popups: which plugin to call back, with the state it returned.
    public var plugin: PluginRef? = nil

    public struct PluginRef: Equatable, Sendable {
        public var pluginId: String
        public var state: JSONValue
    }

    public static func == (a: PopupContent, b: PopupContent) -> Bool {
        a.key == b.key && a.header == b.header && a.date == b.date && a.priority == b.priority && a.icon == b.icon
            && a.accent == b.accent && a.title == b.title && a.blocks == b.blocks && a.tags == b.tags
            && a.attachment?.label == b.attachment?.label && a.attachment?.url == b.attachment?.url && a.buttons == b.buttons
            && a.timeoutSec == b.timeoutSec && a.level == b.level && a.position == b.position && a.topicId == b.topicId
            && a.messageId == b.messageId && a.copyText == b.copyText && a.plugin == b.plugin
    }

    /// Priority as word + symbol + accent together, so colour is never the only signal.
    public static func priorityInfo(_ p: Int) -> (word: String, icon: String, accent: Accent) {
        switch p {
        case 5: ("Urgent", "exclamationmark.triangle.fill", .critical)
        case 4: ("High", "exclamationmark.circle.fill", .warning)
        case 2: ("Low", "arrow.down.circle", .info)
        case 1: ("Min", "arrow.down.to.line.circle", .info)
        default: ("Default", "bell.fill", .info)
        }
    }

    public static func forMessage(_ req: PopupRequest) -> PopupContent {
        let m = req.message
        let s = req.settings
        let info = priorityInfo(m.priority)
        var buttons: [Button] = []
        // ntfy action buttons (max 3 in ntfy); `broadcast` is an Android intent — nothing to do on a Mac.
        for (i, a) in (m.ntfy.actions ?? []).prefix(3).enumerated() {
            switch a.action {
            case "view":
                if let url = SafeOpen.url(a.url) {
                    buttons.append(Button(id: "ntfy-\(i)", label: a.label, action: .open(url), clears: a.clear ?? false,
                                          senderHost: url.host() ?? ""))
                }
            case "http":
                if let r = HTTPAction.request(for: a) {
                    buttons.append(Button(id: "ntfy-\(i)", label: a.label, action: .http(a), clears: a.clear ?? false,
                                          senderHost: r.url?.host() ?? ""))
                }
            default:
                break
            }
        }
        for b in req.extraButtons {
            if let url = SafeOpen.url(b.openURL) {
                buttons.append(Button(id: b.id, label: b.label, style: b.style, action: .open(url)))
            } else if let text = b.copy {
                buttons.append(Button(id: b.id, label: b.label, style: b.style, action: .copy(text)))
            }
        }
        if s.showCopy, !m.body.isEmpty { buttons.append(Button(id: "copy", label: "Copy", action: .copy(m.body))) }
        if m.ntfy.attachment != nil, SafeOpen.url(m.ntfy.attachment?.url) != nil {
            buttons.append(Button(id: "attach-copy", label: "Copy file", action: .attachment(copy: true)))
            buttons.append(Button(id: "attach-download", label: "Download", action: .attachment(copy: false)))
        }
        if s.showOpen, let url = SafeOpen.url(m.ntfy.click) { buttons.append(Button(id: "open", label: "Open", action: .open(url))) }
        // Exactly one prominent (Return) button: Open, else Dismiss — never a sender-defined action,
        // whose label and target the sender chooses.
        if let open = buttons.firstIndex(where: { $0.id == "open" }), !buttons.contains(where: { $0.style == .prominent }) {
            buttons[open].style = .prominent
        }
        let dismissStyle: PopupButton.Style = buttons.contains { $0.style == .prominent } ? .default : .prominent
        buttons.append(Button(id: "dismiss", label: "Dismiss", style: dismissStyle, action: .dismiss))

        var blocks: [Block] = []
        if !m.body.isEmpty { blocks.append(.text(m.body, markdown: m.ntfy.isMarkdown)) }
        let attachment = m.ntfy.attachment.map { a -> (label: String, url: URL?) in
            var label = a.name ?? "Attachment"
            if let size = a.size { label += " · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
            return (label, SafeOpen.url(a.url))
        }
        let emoji = Emoji.prefix(for: m.tags)
        return PopupContent(
            key: m.id, header: req.label, date: m.date, priority: m.priority, icon: info.icon, accent: info.accent,
            title: emoji + (m.title?.isEmpty == false ? m.title! : req.label), blocks: blocks, tags: Emoji.plainTags(m.tags),
            attachment: attachment, buttons: buttons,
            timeoutSec: m.priority == 5 && s.stickyForUrgent ? 0 : s.timeoutSec,
            level: s.level, position: s.position, topicId: m.topicId, messageId: m.ntfy.id, copyText: m.body)
    }

    /// Flood guard's one popup per topic; the count updates in place.
    public static func flood(topicId: UUID, label: String, count: Int) -> PopupContent {
        PopupContent(
            key: "flood-\(topicId.uuidString)", header: label, date: Date(), priority: nil, icon: "rectangle.stack.fill",
            accent: .warning, title: "\(count) more message\(count == 1 ? "" : "s")",
            blocks: [.text("This topic is busy. NtfyBar is holding further alerts until it calms down; every message is in History.", markdown: false)],
            tags: [], attachment: nil,
            buttons: [Button(id: "history", label: "Open History", style: .prominent, action: .showHistory),
                      Button(id: "dismiss", label: "Dismiss", action: .dismiss)],
            timeoutSec: 0, level: .floating, position: .topCenter, topicId: topicId, messageId: nil, copyText: nil)
    }
}
