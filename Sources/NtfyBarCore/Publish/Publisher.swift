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
}

/// JSON publish to the server root (ntfy requires the root URL for JSON bodies).
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
        return body
    }

    /// Returns the id ntfy assigned to the new message.
    public func publish(_ req: PublishRequest, server: ServerConfig, topic: String, priority: Int) async throws -> String? {
        guard let url = server.baseURL else { throw PublishError.invalidServer }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = server.auth.headerValue { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(req, topic: topic, priority: priority))
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
