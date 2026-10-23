import Foundation

public struct NtfyAction: Codable, Equatable, Sendable {
    public var id: String?
    public var action: String  // view | http | broadcast
    public var label: String
    public var url: String?
    public var method: String?
    public var headers: [String: String]?
    public var body: String?
    public var clear: Bool?

    public init(action: String, label: String, url: String? = nil, method: String? = nil,
                headers: [String: String]? = nil, body: String? = nil, clear: Bool? = nil) {
        self.action = action
        self.label = label
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.clear = clear
    }
}

public struct NtfyAttachment: Codable, Equatable, Sendable {
    public var name: String?
    public var url: String?
    public var type: String?
    public var size: Int64?
    public var expires: Int64?

    public init(name: String? = nil, url: String? = nil, type: String? = nil, size: Int64? = nil, expires: Int64? = nil) {
        self.name = name
        self.url = url
        self.type = type
        self.size = size
        self.expires = expires
    }
}

/// One event from ntfy's `/json` stream. `id`, `time` and `event` are required; every other field
/// is decoded on its own, so one odd field never drops the message.
public struct NtfyMessage: Codable, Equatable, Sendable {
    public var id: String
    public var time: Int64
    public var event: String
    public var topic: String
    public var title: String?
    public var message: String?
    public var priority: Int?
    public var tags: [String]?
    public var click: String?
    public var actions: [NtfyAction]?
    public var attachment: NtfyAttachment?
    public var contentType: String?
    public var icon: String?

    public init(id: String, time: Int64, event: String = "message", topic: String, title: String? = nil,
                message: String? = nil, priority: Int? = nil, tags: [String]? = nil, click: String? = nil,
                actions: [NtfyAction]? = nil, attachment: NtfyAttachment? = nil, contentType: String? = nil,
                icon: String? = nil) {
        self.id = id
        self.time = time
        self.event = event
        self.topic = topic
        self.title = title
        self.message = message
        self.priority = priority
        self.tags = tags
        self.click = click
        self.actions = actions
        self.attachment = attachment
        self.contentType = contentType
        self.icon = icon
    }

    private enum CodingKeys: String, CodingKey {
        case id, time, event, topic, title, message, priority, tags, click, actions, attachment, icon
        case contentType = "content_type"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        time = try c.decode(Int64.self, forKey: .time)
        event = try c.decode(String.self, forKey: .event)
        topic = c.value(.topic, "")
        title = c.value(.title, nil)
        message = c.value(.message, nil)
        priority = c.value(.priority, nil)
        tags = c.value(.tags, nil)
        click = c.value(.click, nil)
        actions = c.value(.actions, nil)
        attachment = c.value(.attachment, nil)
        contentType = c.value(.contentType, nil)
        icon = c.value(.icon, nil)
    }

    /// 1…5, ntfy's default 3 when absent or out of range.
    public var priorityValue: Int {
        guard let p = priority, (1...5).contains(p) else { return 3 }
        return p
    }

    public var body: String { message ?? "" }
    public var isMarkdown: Bool { contentType?.lowercased().hasPrefix("text/markdown") ?? false }
}

/// A received message as NtfyBar keeps it: the wire message plus which configured topic it
/// belongs to (by id — never the raw topic string), when it arrived and whether it was replayed.
public struct Message: Equatable, Sendable, Identifiable {
    public var topicId: UUID
    public var ntfy: NtfyMessage
    public var receivedAt: Date
    public var isCatchUp: Bool
    public var read: Bool
    /// The exact JSON line as received (for NTFY_JSON and history), not re-encoded.
    public var raw: String

    public init(topicId: UUID, ntfy: NtfyMessage, receivedAt: Date, isCatchUp: Bool, read: Bool = false, raw: String) {
        self.topicId = topicId
        self.ntfy = ntfy
        self.receivedAt = receivedAt
        self.isCatchUp = isCatchUp
        self.read = read
        self.raw = raw
    }

    public var id: String { "\(topicId.uuidString)/\(ntfy.id)" }
    public var title: String? { ntfy.title }
    public var body: String { ntfy.body }
    public var priority: Int { ntfy.priorityValue }
    public var tags: [String] { ntfy.tags ?? [] }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(ntfy.time)) }
}
