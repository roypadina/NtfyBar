import Foundation

/// Plugins never see raw topic names or server addresses. Every string in plugin-facing JSON is
/// walked and each configured topic name and server URL/host is replaced. Short topic names may
/// over-redact ordinary words — privacy wins.
public struct Redactor: Sendable {
    private let secrets: [(String, String)]

    public init(config: Config) {
        var s: [(String, String)] = []
        for t in config.topics where !t.topic.isEmpty { s.append((t.topic, "[topic]")) }
        for server in config.servers {
            if let url = server.baseURL {
                s.append((url.absoluteString, "[server]"))
                if let host = url.host(), !host.isEmpty { s.append((host, "[server]")) }
            }
        }
        // Longest first, so a URL is replaced before the host inside it.
        secrets = s.sorted { $0.0.count > $1.0.count }
    }

    public func redact(_ s: String) -> String {
        secrets.reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .caseInsensitive) }
    }

    public func redact(_ v: JSONValue) -> JSONValue {
        switch v {
        case let .string(s): .string(redact(s))
        case let .array(a): .array(a.map(redact))
        case let .object(o): .object(Dictionary(uniqueKeysWithValues: o.map { (redact($0.key), redact($0.value)) }))
        default: v
        }
    }

    /// The message as a plugin sees it: no `topic`, no raw line, everything else redacted.
    public func pluginMessage(_ m: Message) -> JSONValue {
        let n = m.ntfy
        var o: [String: JSONValue] = [
            "id": .string(n.id), "time": .number(Double(n.time)), "message": .string(n.body),
            "priority": .number(Double(m.priority)), "tags": .array(m.tags.map(JSONValue.string)),
            "isCatchUp": .bool(m.isCatchUp)
        ]
        if let t = n.title { o["title"] = .string(t) }
        if let c = n.click { o["click"] = .string(c) }
        if let i = n.icon { o["icon"] = .string(i) }
        if let ct = n.contentType { o["contentType"] = .string(ct) }
        if let actions = n.actions, let data = try? JSONEncoder().encode(actions), let v = try? JSONDecoder().decode(JSONValue.self, from: data) {
            o["actions"] = v
        }
        if let a = n.attachment, let data = try? JSONEncoder().encode(a), let v = try? JSONDecoder().decode(JSONValue.self, from: data) {
            o["attachment"] = v
        }
        return redact(.object(o))
    }
}
