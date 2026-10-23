import Foundation

/// Splits a byte stream into lines on 0x0A only. Not `AsyncBytes.lines`: that also splits on CR,
/// NEL (U+0085), LS and PS, and Go's JSON encoder leaves U+0085 unescaped inside strings.
public struct LineSplitter: Sendable {
    public let maxLineBytes: Int
    private var buffer: [UInt8] = []
    private var overflowing = false

    public init(maxLineBytes: Int = 256 * 1024) {
        self.maxLineBytes = maxLineBytes
    }

    /// Returns a completed line (without the newline) when `byte` ends one. A line longer than
    /// `maxLineBytes` is dropped whole, so a hostile server can't grow memory without bound.
    public mutating func push(_ byte: UInt8) -> [UInt8]? {
        if byte == 0x0A {
            defer { buffer.removeAll(keepingCapacity: true); overflowing = false }
            if overflowing {
                Log.stream.error("dropped an over-long stream line")
                return nil
            }
            return buffer
        }
        if overflowing { return nil }
        if buffer.count >= maxLineBytes {
            overflowing = true
            buffer.removeAll()
            return nil
        }
        buffer.append(byte)
        return nil
    }

    public mutating func push(_ data: Data) -> [[UInt8]] {
        data.compactMap { push($0) }
    }
}

public enum StreamEvent: Equatable, Sendable {
    case open(time: Int64)
    case keepalive
    case message(NtfyMessage, raw: String)
    case other(String)  // message_delete, message_clear, poll_request, future events: ignored in v1

    /// nil for blank or malformed lines. Logs only the length — a line can contain a topic.
    public static func parse(_ line: [UInt8]) -> StreamEvent? {
        guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) else { return nil }
        let data = Data(line)
        guard let msg = try? JSONDecoder().decode(NtfyMessage.self, from: data) else {
            Log.stream.error("malformed stream line (\(line.count, privacy: .public) bytes)")
            return nil
        }
        switch msg.event {
        case "open": return .open(time: msg.time)
        case "keepalive": return .keepalive
        case "message": return .message(msg, raw: String(decoding: data, as: UTF8.self))
        default: return .other(msg.event)
        }
    }
}

public struct Backoff: Sendable, Equatable {
    public var base: Double
    public var cap: Double

    public init(base: Double = 1, cap: Double = 60) {
        self.base = base
        self.cap = cap
    }

    /// 1, 2, 4 … capped at 60 s, plus up to 10 % jitter (`jitter` in 0..<1) so many clients don't
    /// reconnect in lockstep after a server restart.
    public func delay(attempt: Int, jitter: Double) -> Double {
        let raw = base * pow(2, Double(min(max(attempt, 0), 30)))
        let d = min(cap, raw)
        return d + d * 0.1 * min(max(jitter, 0), 1)
    }
}

public enum StreamURL {
    /// `{server}/{t1,t2,…}/json[?since=<unix>]`; nil when the server URL is invalid or no topic is valid.
    public static func make(server: URL, topics: [String], since: Int64?) -> URL? {
        let valid = topics.filter(TopicConfig.isValidTopicName)
        guard !valid.isEmpty else { return nil }
        var comps = URLComponents(url: server.appendingPathComponent(valid.joined(separator: ",")).appendingPathComponent("json"),
                                  resolvingAgainstBaseURL: false)
        if let since { comps?.queryItems = [URLQueryItem(name: "since", value: String(since))] }
        return comps?.url
    }

    /// Live vs replayed: a message older than the server's own `open` event time was cached on the
    /// server while we were away. Server time on both sides, so a skewed local clock can't flip it.
    public static func isCatchUp(messageTime: Int64, openTime: Int64?) -> Bool {
        guard let openTime else { return false }
        return messageTime < openTime
    }
}
