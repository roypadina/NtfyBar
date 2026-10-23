import Foundation

/// Refuses every redirect: Foundation would carry the Authorization header to the new host.
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoRedirect()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// One long-lived `GET {server}/{t1,t2,…}/json` per server. Reconnects with exponential backoff,
/// asks for `since=<last message time>` on every reconnect, and stops for good on 401/403 until
/// the config changes (retrying bad credentials just hammers the server).
@MainActor
public final class NtfyStream {
    public enum State: Equatable, Sendable {
        case connecting
        case connected
        case reconnecting(at: Date)
        case authFailed(status: Int)
        /// 3xx: not followed (it would carry credentials elsewhere); the user must enter the final URL.
        case redirected(status: Int)
        case stopped
    }

    public struct Timing: Sendable {
        public var keepaliveTimeout: Double
        public var watchdogInterval: Double
        public var backoff: Backoff

        /// ntfy sends a keepalive every 45 s; two missed ones = dead connection.
        public init(keepaliveTimeout: Double = 90, watchdogInterval: Double = 5, backoff: Backoff = Backoff()) {
            self.keepaliveTimeout = keepaliveTimeout
            self.watchdogInterval = watchdogInterval
            self.backoff = backoff
        }
    }

    public struct Received: Sendable {
        public var topicId: UUID
        public var message: NtfyMessage
        public var raw: String
        public var isCatchUp: Bool
    }

    public let serverId: UUID
    public private(set) var state: State = .stopped
    /// Newest message time seen; sent as `since` on the next connect. nil = first-ever connect.
    public var lastEventTime: Int64?

    private let baseURL: URL
    private let authHeader: String?
    private let topicIds: [String: UUID]  // raw topic → id; stays in memory only
    private let session: URLSession
    private let timing: Timing
    private let now: @Sendable () -> Date
    private let jitter: @Sendable () -> Double
    private let onMessage: @MainActor (Received) -> Void
    private let onState: @MainActor (State) -> Void

    private var runTask: Task<Void, Never>?
    private var attempt = 0
    private var lastActivity = Date()
    private var lastKeepalive: Date?
    /// Longest gap seen between keepalives; a self-hosted server may send them less often than 45 s.
    private var keepaliveGap: Double = 0

    public init(serverId: UUID, baseURL: URL, authHeader: String?, topics: [String: UUID], lastEventTime: Int64?,
                session: URLSession, timing: Timing = Timing(),
                now: @escaping @Sendable () -> Date = { Date() },
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
                onMessage: @escaping @MainActor (Received) -> Void,
                onState: @escaping @MainActor (State) -> Void) {
        self.serverId = serverId
        self.baseURL = baseURL
        self.authHeader = authHeader
        self.topicIds = topics
        self.lastEventTime = lastEventTime
        self.session = session
        self.timing = timing
        self.now = now
        self.jitter = jitter
        self.onMessage = onMessage
        self.onState = onState
    }

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        set(.stopped)
    }

    /// Network change / wake: drop the (possibly dead) connection and reconnect right away.
    /// A stream stopped by 401/403 or a redirect stays stopped — only a config edit rebuilds it.
    public func reconnectNow() {
        if isTerminal { return }
        runTask?.cancel()
        runTask = nil
        attempt = 0
        start()
    }

    var isTerminal: Bool {
        switch state {
        case .authFailed, .redirected: true
        default: false
        }
    }

    /// The engine moves the cursor only after the message is safely in history.
    public func advanceCursor(to time: Int64) {
        lastEventTime = max(lastEventTime ?? 0, time)
    }

    private func set(_ new: State) {
        guard new != state else { return }
        state = new
        onState(new)
    }

    private func run() async {
        while !Task.isCancelled {
            set(.connecting)
            let outcome = await connectOnce()
            if Task.isCancelled { return }
            switch outcome {
            case let .authFailed(status):
                Log.stream.error("server rejected credentials (HTTP \(status, privacy: .public)); not reconnecting until settings change")
                set(.authFailed(status: status))
                runTask = nil
                return
            case let .redirected(status):
                Log.stream.error("server answered with a redirect (HTTP \(status, privacy: .public)); not following it")
                set(.redirected(status: status))
                runTask = nil
                return
            case .ended:
                break
            }
            let delay = timing.backoff.delay(attempt: attempt, jitter: jitter())
            attempt += 1
            set(.reconnecting(at: now().addingTimeInterval(delay)))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private enum Outcome { case ended, authFailed(Int), redirected(Int) }

    private func connectOnce() async -> Outcome {
        guard let url = StreamURL.make(server: baseURL, topics: Array(topicIds.keys), since: lastEventTime) else {
            return .ended
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timing.keepaliveTimeout + 30
        if let authHeader { request.setValue(authHeader, forHTTPHeaderField: "Authorization") }

        lastActivity = now()
        let reader = Task { [weak self] () -> Outcome in
            guard let self else { return .ended }
            return try await self.read(request)
        }
        let watchdog = Task { [weak self, timing] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(timing.watchdogInterval))
                guard let self, !Task.isCancelled else { return }
                let limit = max(timing.keepaliveTimeout, 2 * self.keepaliveGap)
                if self.now().timeIntervalSince(self.lastActivity) > limit {
                    Log.stream.info("nothing received for \(Int(limit), privacy: .public) s; reconnecting")
                    reader.cancel()
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        return await withTaskCancellationHandler {
            do {
                return try await reader.value
            } catch {
                if !(error is CancellationError) {
                    Log.stream.info("stream ended: \(error.localizedDescription, privacy: .public)")
                }
                return .ended
            }
        } onCancel: {
            reader.cancel()
        }
    }

    private func read(_ request: URLRequest) async throws -> Outcome {
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirect.shared)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { return .authFailed(status) }
        if (300..<400).contains(status) { return .redirected(status) }
        guard status == 200 else {
            Log.stream.error("stream HTTP \(status, privacy: .public)")
            return .ended
        }
        lastActivity = now()
        var splitter = LineSplitter()
        var openTime: Int64?
        for try await byte in bytes {
            guard let line = splitter.push(byte) else { continue }
            lastActivity = now()
            switch StreamEvent.parse(line) {
            case let .open(time):
                openTime = time
                attempt = 0
                set(.connected)
            case let .message(msg, raw):
                guard let topicId = topicIds[msg.topic] else { continue }
                onMessage(Received(topicId: topicId, message: msg, raw: raw,
                                   isCatchUp: StreamURL.isCatchUp(messageTime: msg.time, openTime: openTime)))
            case .keepalive:
                let t = now()
                if let last = lastKeepalive { keepaliveGap = max(keepaliveGap, t.timeIntervalSince(last)) }
                lastKeepalive = t
            case .other, .none:
                break
            }
        }
        return .ended
    }
}
