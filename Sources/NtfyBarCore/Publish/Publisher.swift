import Foundation

extension QuietHours {
    /// Caps `priority` at `maxPriority` while inside the window. Handles windows across midnight
    /// (20:00–09:00). start == end = empty window. Times are local wall-clock "HH:mm".
    public func cap(_ priority: Int, at date: Date, calendar: Calendar = .current) -> Int {
        guard enabled, contains(date, calendar: calendar) else { return priority }
        return min(priority, maxPriority)
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard let s = Self.minutes(start), let e = Self.minutes(end), s != e else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let t = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return s < e ? (t >= s && t < e) : (t >= s || t < e)
    }

    public static func isValidTime(_ hhmm: String) -> Bool { minutes(hhmm) != nil }

    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
}

/// Sliding-window limiter (per key).
public struct RateLimiter: Sendable {
    public let limit: Int
    public let window: TimeInterval
    private var hits: [String: [Date]] = [:]

    public init(limit: Int, window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    public mutating func allow(_ key: String, at now: Date) -> Bool {
        var h = hits[key, default: []].filter { now.timeIntervalSince($0) < window }
        guard h.count < limit else { hits[key] = h; return false }
        h.append(now)
        hits[key] = h
        return true
    }
}

public enum PublishError: Error, Equatable {
    case unknownTopic
    case invalidServer
    case rateLimited
    case http(Int)
    case transport(String)
    case fileTooLarge(String)
    case tooManyFiles
    case unreadableFile(String)
    /// A multi-item send stopped after `sent` messages went out; re-sending repeats those.
    indirect case partial(sent: Int, of: Int, cause: PublishError)

    /// One line for "Couldn't send: …".
    public var reason: String {
        switch self {
        case .unknownTopic: "the topic no longer exists"
        case .invalidServer: "the server URL is not valid"
        case .rateLimited, .http(429): "too many messages, try again in a minute"
        case .http(401), .http(403): "not allowed on this topic"
        case .http(413): "too large for the server"
        case let .http(code): "HTTP \(code)"
        case .transport: "server unreachable"
        case let .fileTooLarge(name): "“\(name)” is over 100 MB"
        case .tooManyFiles: "more than \(Outgoing.maxFiles) files"
        case let .unreadableFile(name): "can't read “\(name)”"
        case let .partial(sent, total, cause): "sent \(sent) of \(total), then \(cause.reason)"
        }
    }
}

/// What the user sends from the menu or the Publish window. Each item is one ntfy message.
public enum Outgoing: Equatable, Sendable {
    case text(String)
    case file(URL)
    /// Clipboard picture as PNG bytes, sent as `clip.png`.
    case image(Data)

    public static let maxTextBytes = 4000
    public static let maxCopyBytes = 2000
    public static let maxFileBytes = 100 * 1024 * 1024
    public static let maxFiles = 20

    /// Text up to 4000 B goes as JSON (with a Copy button up to 2000 B); longer text goes byte-exact
    /// as `clip.txt`. Files and images go as attachments named after the file. Checks every item
    /// (count, size, readable) before anything is uploaded.
    public static func requests(_ items: [Outgoing], base: PublishRequest) throws -> [PublishRequest] {
        guard items.filter({ if case .text = $0 { false } else { true } }).count <= maxFiles else { throw PublishError.tooManyFiles }
        return try items.map { item in
            var r = base
            switch item {
            case let .text(text):
                let bytes = text.utf8.count
                if bytes <= maxTextBytes {
                    r.message = text
                    r.copyButton = bytes <= maxCopyBytes
                } else {
                    r.message = String(text.prefix(80)) + "…"
                    r.file = PublishFile(name: "clip.txt", data: Data(text.utf8))
                }
            case let .file(url):
                let name = url.lastPathComponent
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true, let size = values?.fileSize else { throw PublishError.unreadableFile(name) }
                guard size <= maxFileBytes else { throw PublishError.fileTooLarge(name) }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw PublishError.unreadableFile(name) }
                r.file = PublishFile(name: name, data: data)
                r.message = name
            case let .image(png):
                guard png.count <= maxFileBytes else { throw PublishError.fileTooLarge("clip.png") }
                r.file = PublishFile(name: "clip.png", data: png)
                r.message = "clip.png"
            }
            return r
        }
    }
}

/// Publishes one message: JSON to the server root (ntfy requires the root URL for JSON bodies),
/// or a file as PUT to the topic with its fields as query parameters (UTF-8 safe, unlike headers).
public struct Publisher: Sendable {
    public let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public static func body(_ req: PublishRequest, topic: String, priority: Int) -> [String: Any] {
        var body: [String: Any] = ["topic": topic, "message": req.message, "priority": priority]
        if let title = req.title { body["title"] = title }
        if !req.tags.isEmpty { body["tags"] = req.tags }
        if let click = req.click, SafeOpen.url(click) != nil { body["click"] = click }
        if let delay = req.delay { body["delay"] = "\(delay)s" }
        if req.copyButton { body["actions"] = [["action": "copy", "label": "Copy", "value": req.message]] }
        return body
    }

    /// `PUT <server>/<topic>?filename=&title=&tags=&message=`. Everything but unreserved characters
    /// is percent-encoded: ntfy (Go) reads `+` as a space and drops pairs that contain `;`.
    public static func fileURL(_ req: PublishRequest, file: PublishFile, base: URL, topic: String) -> URL? {
        var pairs = [("filename", file.name)]
        if let title = req.title { pairs.append(("title", title)) }
        if !req.tags.isEmpty { pairs.append(("tags", req.tags.joined(separator: ","))) }
        pairs.append(("message", req.message))
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard var comps = URLComponents(url: base.appendingPathComponent(topic), resolvingAgainstBaseURL: false) else { return nil }
        comps.percentEncodedQuery = pairs.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
        return comps.url
    }

    /// Returns the id ntfy assigned to the new message.
    public func publish(_ req: PublishRequest, server: ServerConfig, topic: String, priority: Int) async throws -> String? {
        guard let base = server.baseURL else { throw PublishError.invalidServer }
        var request: URLRequest
        if let file = req.file {
            guard let url = Self.fileURL(req, file: file, base: base, topic: topic) else { throw PublishError.invalidServer }
            request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = "PUT"
            request.setValue(String(priority), forHTTPHeaderField: "X-Priority")
            request.httpBody = file.data
        } else {
            request = URLRequest(url: base, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(req, topic: topic, priority: priority))
        }
        if let auth = server.auth.headerValue { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request, delegate: NoRedirect.shared)
        } catch {
            throw PublishError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw PublishError.http(status) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String
    }
}

/// ntfy `http` action buttons: the request exactly as the message describes it — and never the
/// server's Authorization header (the action URL may point anywhere).
public enum HTTPAction {
    public static func request(for action: NtfyAction) -> URLRequest? {
        guard action.action == "http", let url = SafeOpen.url(action.url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = (action.method?.isEmpty == false ? action.method! : "POST").uppercased()
        for (k, v) in action.headers ?? [:] { request.setValue(v, forHTTPHeaderField: k) }
        if let body = action.body, request.httpMethod != "GET" { request.httpBody = Data(body.utf8) }
        return request
    }

    public static func perform(_ action: NtfyAction, session: URLSession) async -> Bool {
        guard let request = request(for: action) else { return false }
        guard let (_, response) = try? await session.data(for: request, delegate: NoRedirect.shared) else { return false }
        return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
