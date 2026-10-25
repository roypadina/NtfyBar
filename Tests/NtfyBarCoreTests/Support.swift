import Foundation
@testable import NtfyBarCore

/// Scripted fake HTTP server for URLSession. Each test registers a unique host, so suites can run
/// in parallel. `handler(request, attempt)` returns the steps for that connection attempt; a
/// script that doesn't end with `.end` leaves the connection open (a live stream) until cancelled.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Step: Sendable {
        case status(Int, [String: String] = [:])
        case data(Data)
        case line(String)  // data + "\n"
        case delay(Double)
        case end
        case fail
        /// Waits (up to 5 s) until the condition holds, e.g. "the POST has arrived".
        case until(@Sendable () -> Bool)
    }

    typealias Handler = @Sendable (URLRequest, Int) -> [Step]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var log: [String: [URLRequest]] = [:]
    nonisolated(unsafe) private static var bodies: [String: [Data]] = [:]

    static func register(_ host: String, _ handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler }
    }

    static func requests(_ host: String) -> [URLRequest] { lock.withLock { log[host] ?? [] } }
    static func bodies(_ host: String) -> [Data] { lock.withLock { bodies[host] ?? [] } }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }

    private let stopped = NSLock()
    nonisolated(unsafe) private var isStopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let (handler, attempt): (Handler?, Int) = Self.lock.withLock {
            Self.log[host, default: []].append(request)
            Self.bodies[host, default: []].append(body)
            return (Self.handlers[host], (Self.log[host]?.count ?? 1) - 1)
        }
        let steps = handler?(request, attempt) ?? [.status(404), .end]
        let url = request.url!
        DispatchQueue.global().async { [self] in
            for step in steps {
                if stopped.withLock({ isStopped }) { return }
                switch step {
                case let .status(code, headers):
                    let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                                               headerFields: headers.merging(["Content-Type": "application/x-ndjson"]) { a, _ in a })!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                case let .data(d):
                    client?.urlProtocol(self, didLoad: d)
                case let .line(s):
                    client?.urlProtocol(self, didLoad: Data((s + "\n").utf8))
                case let .delay(seconds):
                    let until = Date().addingTimeInterval(seconds)
                    while Date() < until {
                        if stopped.withLock({ isStopped }) { return }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                case let .until(condition):
                    let deadline = Date().addingTimeInterval(5)
                    while !condition() && Date() < deadline {
                        if stopped.withLock({ isStopped }) { return }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                case .end:
                    client?.urlProtocolDidFinishLoading(self)
                    return
                case .fail:
                    client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                    return
                }
            }
        }
    }

    override func stopLoading() {
        stopped.withLock { isStopped = true }
    }
}

func uniqueHost() -> String { "t\(UUID().uuidString.prefix(8).lowercased()).example" }

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ntfybar-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Polls `condition` on the main actor until true or `timeout` passes.
@MainActor
func eventually(timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

func ntfyLine(id: String, time: Int64, topic: String, title: String? = nil, message: String = "hello",
              priority: Int? = nil, extra: [String: Any] = [:]) -> String {
    var obj: [String: Any] = ["id": id, "time": time, "event": "message", "topic": topic, "message": message]
    if let title { obj["title"] = title }
    if let priority { obj["priority"] = priority }
    obj.merge(extra) { _, b in b }
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

func openLine(time: Int64, topic: String) -> String {
    #"{"id":"open1","time":\#(time),"event":"open","topic":"\#(topic)"}"#
}

func makeMessage(topicId: UUID, id: String = UUID().uuidString, time: Int64 = 1_700_000_000, title: String? = "T",
                 body: String = "hello", priority: Int? = nil, tags: [String]? = nil, click: String? = nil,
                 isCatchUp: Bool = false, receivedAt: Date = Date()) -> Message {
    let n = NtfyMessage(id: id, time: time, topic: "ntfybar-9f3a1c7b2e", title: title, message: body, priority: priority,
                        tags: tags, click: click)
    let raw = String(decoding: try! JSONEncoder().encode(n), as: UTF8.self)
    return Message(topicId: topicId, ntfy: n, receivedAt: receivedAt, isCatchUp: isCatchUp, raw: raw)
}

extension Array {
    /// nil instead of a crash when a test's request never arrived.
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Built-ins plus a stub plugin card action `id` that answers with a fixed plugin popup (or throws).
@MainActor
func cardRegistry(_ id: String = "com.example.card.show", throwing: Bool = false) -> ProviderRegistry {
    let r = ProviderRegistry()
    r.register(ProviderDescriptor(id: id, kind: .action, name: "Show card", description: "", packageId: "com.example.card")) { ctx, _ in
        if throwing { throw ProviderError.failed("broken plugin") }
        let spec = try PopupSpec.parse(.object(["title": .string("Card")]))
        return ActionOutput([.pluginPopup(PluginPopupRequest(pluginId: "com.example.card", pluginName: "Card", spec: spec, topicId: ctx.topic.id,
                                                             messageId: ctx.message.ntfy.id, label: ctx.label,
                                                             defaults: ctx.topic.popup.settings(timeoutSec: 0)))])
    }
    return r
}
