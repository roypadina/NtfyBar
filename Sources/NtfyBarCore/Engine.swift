import Foundation
import Network
import Observation

/// Wires config → one stream per server → history (dedupe) → dispatcher → effects.
/// The app target observes it and performs the effects; tests drive it with a stubbed URLSession.
@Observable
@MainActor
public final class Engine {
    public private(set) var config: Config
    public private(set) var streamStates: [UUID: NtfyStream.State] = [:]
    public private(set) var unreadCount = 0
    public private(set) var recent: [Message] = []

    @ObservationIgnored public let store: ConfigStore
    @ObservationIgnored public let history: HistoryStore
    @ObservationIgnored public let dispatcher: Dispatcher
    @ObservationIgnored public var onEffects: (([Effect]) -> Void)?

    @ObservationIgnored private var streams: [UUID: NtfyStream] = [:]
    @ObservationIgnored private var signatures: [UUID: String] = [:]
    @ObservationIgnored private var state: StreamState
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let timing: NtfyStream.Timing
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let catchUpDebounce: Double
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var dailyTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var seenFirstPath = false
    @ObservationIgnored private var lastReconnectAll = Date.distantPast

    public init(store: ConfigStore = ConfigStore(), session: URLSession = Engine.makeSession(),
                timing: NtfyStream.Timing = NtfyStream.Timing(), catchUpDebounce: Double = 2,
                dispatcher: Dispatcher = Dispatcher(), now: @escaping @Sendable () -> Date = { Date() }) throws {
        try store.ensureDirectory()
        self.store = store
        self.config = store.loadConfig()
        self.state = store.loadState()
        self.history = try HistoryStore(url: store.historyURL)
        self.dispatcher = dispatcher
        self.session = session
        self.timing = timing
        self.catchUpDebounce = catchUpDebounce
        self.now = now
        refreshCounters()
    }

    public static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 7 * 24 * 3600
        c.waitsForConnectivity = false
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c)
    }

    // MARK: lifecycle

    public func start() {
        applyStreams()
        purgeAll()
        dailyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(24 * 3600))
                self?.purgeAll()
            }
        }
    }

    public func stop() {
        streams.values.forEach { $0.stop() }
        streams.removeAll()
        signatures.removeAll()
        dailyTask?.cancel()
        pathMonitor?.cancel()
    }

    /// Network change or wake: every stream reconnects now instead of waiting for its watchdog.
    public func reconnectAll() {
        guard now().timeIntervalSince(lastReconnectAll) > 1 else { return }
        lastReconnectAll = now()
        streams.values.forEach { $0.reconnectNow() }
    }

    public func startNetworkMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "com.padina.ntfybar.path"))
        pathMonitor = monitor
    }

    private func pathChanged(satisfied: Bool) {
        guard seenFirstPath else { seenFirstPath = true; return }  // the first update just reports the current path
        if satisfied { reconnectAll() }
    }

    // MARK: config

    public func update(_ change: (inout Config) -> Void) throws {
        var c = config
        change(&c)
        try store.saveConfig(c)
        config = c
        applyStreams()
    }

    /// After "Edit config file…": re-read config.json from disk.
    public func reloadFromDisk() {
        config = store.loadConfig()
        applyStreams()
    }

    // MARK: history actions

    public func markAllRead() {
        history.markRead()
        refreshCounters()
    }

    public func markRead(_ m: Message) {
        history.markRead(topicId: m.topicId, id: m.ntfy.id)
        refreshCounters()
    }

    public func clearHistory(topicId: UUID?) {
        history.clear(topicId: topicId)
        refreshCounters()
    }

    public func refreshCounters() {
        unreadCount = history.unreadCount()
        recent = history.recent(limit: 8)
    }

    // MARK: streams

    private func applyStreams() {
        var wanted: [UUID: (server: ServerConfig, topics: [String: UUID])] = [:]
        for topic in config.topics where topic.enabled && TopicConfig.isValidTopicName(topic.topic) {
            guard let server = config.server(topic.serverId), server.baseURL != nil else { continue }
            wanted[server.id, default: (server, [:])].topics[topic.topic] = topic.id
        }
        for (id, stream) in streams where wanted[id] == nil {
            stream.stop()
            streams[id] = nil
            signatures[id] = nil
            streamStates[id] = nil
        }
        for (serverId, w) in wanted {
            let signature = ([w.server.url, w.server.auth.headerValue ?? ""]
                + w.topics.map { "\($0.key)=\($0.value)" }.sorted()).joined(separator: "\n")
            if signatures[serverId] == signature { continue }
            streams[serverId]?.stop()
            guard let base = w.server.baseURL else { continue }
            let stream = NtfyStream(
                serverId: serverId, baseURL: base, authHeader: w.server.auth.headerValue, topics: w.topics,
                lastEventTime: state.lastEventTime[serverId.uuidString], session: session, timing: timing, now: now,
                onMessage: { [weak self] in self?.receive($0, serverId: serverId) },
                onState: { [weak self] in self?.streamStates[serverId] = $0 })
            streams[serverId] = stream
            signatures[serverId] = signature
            stream.start()
        }
    }

    private func receive(_ r: NtfyStream.Received, serverId: UUID) {
        let m = Message(topicId: r.topicId, ntfy: r.message, receivedAt: now(), isCatchUp: r.isCatchUp, raw: r.raw)
        let key = serverId.uuidString
        if r.message.time > state.lastEventTime[key] ?? 0 {
            state.lastEventTime[key] = r.message.time
            try? store.saveState(state)
        }
        guard history.insert(m) else { return }  // replay of a message we already have
        if let topic = config.topic(m.topicId) {
            history.purge(topicId: topic.id, keep: topic.retention.count, days: topic.retention.days, now: now())
        }
        refreshCounters()
        let effects = dispatcher.handle(m, config: config, now: now())
        if !effects.isEmpty { onEffects?(effects) }
        if dispatcher.hasPendingCatchUp { scheduleCatchUpFlush() }
    }

    private func scheduleCatchUpFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self, catchUpDebounce] in
            try? await Task.sleep(for: .seconds(catchUpDebounce))
            guard !Task.isCancelled, let self else { return }
            let effects = self.dispatcher.flushCatchUp(config: self.config, now: self.now())
            if !effects.isEmpty { self.onEffects?(effects) }
        }
    }

    private func purgeAll() {
        for topic in config.topics {
            history.purge(topicId: topic.id, keep: topic.retention.count, days: topic.retention.days, now: now())
        }
        refreshCounters()
    }
}
