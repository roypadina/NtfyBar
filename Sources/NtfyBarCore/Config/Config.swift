import Foundation

// Every struct here decodes tolerantly: each field falls back to its default on its own, so an old,
// partial or hand-edited config.json never wipes the whole config (MeetAlert Store.Config pattern).
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

public enum ServerAuth: Codable, Equatable, Sendable {
    case none
    case basic(user: String, pass: String)
    case token(String)

    private enum CodingKeys: String, CodingKey { case type, user, pass, token }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch c.value(.type, "none") {
        case "basic": self = .basic(user: c.value(.user, ""), pass: c.value(.pass, ""))
        case "token": self = .token(c.value(.token, ""))
        default: self = .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try c.encode("none", forKey: .type)
        case let .basic(user, pass):
            try c.encode("basic", forKey: .type)
            try c.encode(user, forKey: .user)
            try c.encode(pass, forKey: .pass)
        case let .token(token):
            try c.encode("token", forKey: .type)
            try c.encode(token, forKey: .token)
        }
    }

    /// Value for the `Authorization` header, nil when the server needs none.
    public var headerValue: String? {
        switch self {
        case .none: return nil
        case let .basic(user, pass): return "Basic " + Data("\(user):\(pass)".utf8).base64EncodedString()
        case let .token(token): return token.isEmpty ? nil : "Bearer \(token)"
        }
    }
}

public struct ServerConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var url: String
    public var auth: ServerAuth

    public init(id: UUID = UUID(), url: String, auth: ServerAuth = .none) {
        self.id = id
        self.url = url
        self.auth = auth
    }

    private enum CodingKeys: String, CodingKey { case id, url, auth }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        url = c.value(.url, "https://ntfy.sh")
        auth = c.value(.auth, .none)
    }

    /// Base URL without a trailing slash, or nil when invalid: http/https with a host, and no
    /// user info, query or fragment (they would leak into or break every request built on it).
    public var baseURL: URL? { Self.validatedURL(url) }

    public static func validatedURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = comps.host, !host.isEmpty,
              comps.user == nil, comps.password == nil, comps.query == nil, comps.fragment == nil
        else { return nil }
        return comps.url
    }
}

public struct PopupSettings: Codable, Equatable, Sendable {
    public enum Level: String, Codable, Sendable, CaseIterable { case floating, overFullScreen }
    public enum Position: String, Codable, Sendable, CaseIterable { case topCenter, topRight }

    public var enabled = false
    public var timeoutSec = 20  // 0 = sticky
    public var stickyForUrgent = true
    public var level: Level = .floating
    public var position: Position = .topCenter
    /// Priority ("1"…"5") → system sound name. String keys: JSON objects can't have Int keys.
    public var soundByPriority: [String: String] = ["5": "Basso", "4": "Glass"]
    public var showCopy = true
    public var showOpen = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, timeoutSec, stickyForUrgent, level, position, soundByPriority, showCopy, showOpen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PopupSettings()
        enabled = c.value(.enabled, d.enabled)
        timeoutSec = max(0, c.value(.timeoutSec, d.timeoutSec))
        stickyForUrgent = c.value(.stickyForUrgent, d.stickyForUrgent)
        level = c.value(.level, d.level)
        position = c.value(.position, d.position)
        soundByPriority = c.value(.soundByPriority, d.soundByPriority)
        showCopy = c.value(.showCopy, d.showCopy)
        showOpen = c.value(.showOpen, d.showOpen)
    }

    public func sound(forPriority priority: Int) -> String? { soundByPriority[String(priority)] }
}

public struct CommandSettings: Codable, Equatable, Sendable {
    public var command: String
    public var timeoutSec = 30
    public var notifyOnFailure = true

    public init(command: String, timeoutSec: Int = 30, notifyOnFailure: Bool = true) {
        self.command = command
        self.timeoutSec = timeoutSec
        self.notifyOnFailure = notifyOnFailure
    }

    private enum CodingKeys: String, CodingKey { case command, timeoutSec, notifyOnFailure }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = c.value(.command, "")
        timeoutSec = max(1, c.value(.timeoutSec, 30))
        notifyOnFailure = c.value(.notifyOnFailure, true)
    }
}

public struct Retention: Codable, Equatable, Sendable {
    public var count = 500
    public var days = 30

    public init(count: Int = 500, days: Int = 30) {
        self.count = count
        self.days = days
    }

    private enum CodingKeys: String, CodingKey { case count, days }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = max(1, c.value(.count, 500))
        days = max(1, c.value(.days, 30))
    }
}

public struct TopicConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var serverId: UUID
    /// The raw topic name — a capability. Only the topic editor and config.json ever show it.
    public var topic: String
    public var label: String
    public var enabled = true
    public var notify = true
    public var popup = PopupSettings()
    public var copyToClipboard = false
    public var downloadAttachments = false
    public var copyAttachment = false
    public var command: CommandSettings? = nil
    public var retention = Retention()
    public var processMissed = false
    public var soundOverride: String? = nil

    public init(id: UUID = UUID(), serverId: UUID, topic: String, label: String) {
        self.id = id
        self.serverId = serverId
        self.topic = topic
        self.label = label
    }

    private enum CodingKeys: String, CodingKey {
        case id, serverId, topic, label, enabled, notify, popup, copyToClipboard, downloadAttachments, copyAttachment, command, retention, processMissed, soundOverride
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        serverId = c.value(.serverId, UUID())
        topic = c.value(.topic, "")
        label = c.value(.label, "")
        enabled = c.value(.enabled, true)
        notify = c.value(.notify, true)
        popup = c.value(.popup, PopupSettings())
        copyToClipboard = c.value(.copyToClipboard, false)
        downloadAttachments = c.value(.downloadAttachments, false)
        copyAttachment = c.value(.copyAttachment, false)
        command = c.value(.command, nil)
        retention = c.value(.retention, Retention())
        processMissed = c.value(.processMissed, false)
        soundOverride = c.value(.soundOverride, nil)
    }

    /// ntfy topic names: a comma would subscribe a second topic, `/` or `?` would inject into the URL path.
    public static func isValidTopicName(_ name: String) -> Bool {
        name.range(of: #"^[-_A-Za-z0-9]{1,64}$"#, options: .regularExpression) != nil
    }

    public var displayLabel: String { label.isEmpty ? "Untitled topic" : label }

    /// "ntfybar-" + 22 base62 characters (~131 bits): unguessable on a public server.
    public static func randomName() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var g = SystemRandomNumberGenerator()
        return "ntfybar-" + String((0..<22).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &g)] })
    }
}

public struct PluginGrant: Codable, Equatable, Sendable {
    /// Permissions currently allowed (the user can switch single ones off).
    public var permissions: [String]
    /// Everything the user was shown and agreed to. A plugin update that declares anything beyond
    /// this needs consent again.
    public var consented: [String]
    /// Where the consented package came from: "bundled", "installed" or "local:<path>". A package
    /// with the same id from a different source gets no grants (and needs its own consent).
    public var source: String

    public init(permissions: [String], consented: [String]? = nil, source: String) {
        self.permissions = permissions
        self.consented = consented ?? permissions
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case permissions, consented, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        permissions = c.value(.permissions, [])
        consented = c.value(.consented, permissions)
        source = c.value(.source, "")
    }
}

public struct PluginSettings: Codable, Equatable, Sendable {
    public static let officialMarketplace = "https://raw.githubusercontent.com/roypadina/NtfyBar-Plugins/main/marketplace.json"

    public var disabledIds: [String] = []
    public var grants: [String: PluginGrant] = [:]
    public var localFolders: [String] = []
    public var marketplaces: [String] = [PluginSettings.officialMarketplace]
    /// Installed package id → the marketplace URL it came from (for the "Unverified source" badge).
    public var installedFrom: [String: String] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey { case disabledIds, grants, localFolders, marketplaces, installedFrom }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        disabledIds = c.value(.disabledIds, [])
        grants = c.value(.grants, [:])
        localFolders = c.value(.localFolders, [])
        marketplaces = c.value(.marketplaces, [PluginSettings.officialMarketplace])
        installedFrom = c.value(.installedFrom, [:])
    }
}

public struct QuietHours: Codable, Equatable, Sendable {
    public var enabled = true
    public var start = "20:00"
    public var end = "09:00"
    public var maxPriority = 4

    public init(enabled: Bool = true, start: String = "20:00", end: String = "09:00", maxPriority: Int = 4) {
        self.enabled = enabled
        self.start = start
        self.end = end
        self.maxPriority = maxPriority
    }

    private enum CodingKeys: String, CodingKey { case enabled, start, end, maxPriority }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, true)
        start = c.value(.start, "20:00")
        end = c.value(.end, "09:00")
        maxPriority = min(5, max(1, c.value(.maxPriority, 4)))
    }
}

public struct Config: Codable, Equatable, Sendable {
    public var servers: [ServerConfig] = [ServerConfig(url: "https://ntfy.sh")]
    public var topics: [TopicConfig] = []
    public var plugins = PluginSettings()
    public var quietHours = QuietHours()
    public var launchAtLogin = true
    public var didRegisterLoginItem = false
    /// Notifications paused until this date; `Date.distantFuture` = until resumed.
    public var pausedUntil: Date? = nil

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case servers, topics, plugins, quietHours, launchAtLogin, didRegisterLoginItem, pausedUntil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        servers = c.value(.servers, d.servers)
        topics = c.value(.topics, [])
        plugins = c.value(.plugins, PluginSettings())
        quietHours = c.value(.quietHours, QuietHours())
        launchAtLogin = c.value(.launchAtLogin, true)
        didRegisterLoginItem = c.value(.didRegisterLoginItem, false)
        pausedUntil = c.value(.pausedUntil, nil)
    }

    public func server(_ id: UUID) -> ServerConfig? { servers.first { $0.id == id } }
    public func topic(_ id: UUID) -> TopicConfig? { topics.first { $0.id == id } }

    public func isPaused(at now: Date) -> Bool { pausedUntil.map { $0 > now } ?? false }
}
