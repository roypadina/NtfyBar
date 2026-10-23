import Foundation

/// What should happen in response to a message. The Dispatcher decides (pure, unit-tested);
/// the app target's EffectPerformer does it (AppKit, notifications, processes).
public enum Effect: Equatable, Sendable {
    case notify(Message, label: String)
    case popup(PopupRequest)
    /// Flood guard: one popup per topic that counts what was collapsed into it.
    case summaryPopup(topicId: UUID, label: String, count: Int)
    case summaryNotification(topicId: UUID, label: String, count: Int)
    case copy(String)
    case playSound(String)
    case runCommand(CommandSettings, Message, label: String)
    case runShortcut(name: String, Message)
    case openURL(URL)
    case publish(PublishRequest)

    /// Pause suppresses everything that interrupts; storing, copying and publishing go on.
    var interrupts: Bool {
        switch self {
        case .notify, .popup, .summaryPopup, .summaryNotification, .playSound, .runCommand, .runShortcut, .openURL: true
        case .copy, .publish: false
        }
    }
}

public struct PopupRequest: Equatable, Sendable {
    public var message: Message
    public var label: String
    public var settings: PopupSettings
    public var extraButtons: [PopupButton]

    public init(message: Message, label: String, settings: PopupSettings, extraButtons: [PopupButton] = []) {
        self.message = message
        self.label = label
        self.settings = settings
        self.extraButtons = extraButtons
    }
}

public struct PopupButton: Equatable, Sendable, Codable {
    public enum Style: String, Codable, Sendable { case `default`, prominent, destructive }

    public var id: String
    public var label: String
    public var style: Style
    /// What a rule's extra button does: an http(s) URL to open, or a template copied to the clipboard.
    public var openURL: String?
    public var copy: String?

    public init(id: String, label: String, style: Style = .default, openURL: String? = nil, copy: String? = nil) {
        self.id = id
        self.label = label
        self.style = style
        self.openURL = openURL
        self.copy = copy
    }
}

public struct PublishRequest: Equatable, Sendable {
    public var topicId: UUID
    public var title: String?
    public var message: String
    public var priority: Int
    public var tags: [String]
    public var click: String?

    public init(topicId: UUID, title: String? = nil, message: String, priority: Int = 3, tags: [String] = [], click: String? = nil) {
        self.topicId = topicId
        self.title = title
        self.message = message
        self.priority = priority
        self.tags = tags
        self.click = click
    }
}
