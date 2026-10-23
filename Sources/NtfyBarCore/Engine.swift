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

    public private(set) var rules: RulesFile
    public private(set) var pluginPackages: [PluginManager.Package] = []

    @ObservationIgnored public let store: ConfigStore
    @ObservationIgnored public let history: HistoryStore
    @ObservationIgnored public let dispatcher: Dispatcher
    @ObservationIgnored public var onEffects: (([Effect]) -> Void)?
    /// AppKit side effects for plugins (clipboard, browser), set by the app.
    @ObservationIgnored public var onCopy: ((String) -> Void)?
    @ObservationIgnored public var onOpen: ((URL) -> Void)?
    @ObservationIgnored public private(set) var plugins: PluginManager!

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
    @ObservationIgnored public let commands = CommandQueue()
    @ObservationIgnored private let publisher: Publisher
    /// Loop guard: ids ntfy returned for our own publishes, and signatures of publishes still in
    /// flight (the echo can arrive on the stream before the POST returns its id).
    @ObservationIgnored private var ownIds: [String: Date] = [:]
    @ObservationIgnored private var ownPending: [String: Date] = [:]
    @ObservationIgnored private var publishLimiter = RateLimiter(limit: 10, window: 60)

    public init(store: ConfigStore = ConfigStore(), session: URLSession = Engine.makeSession(),
                timing: NtfyStream.Timing = NtfyStream.Timing(), catchUpDebounce: Double = 2,
                dispatcher: Dispatcher = Dispatcher(), bundledPlugins: URL? = nil, appVersion: String = "1.0.0",
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        try store.ensureDirectory()
        self.store = store
        self.config = store.loadConfig()
        self.state = store.loadState()
        self.history = try HistoryStore(url: store.historyURL)
        self.rules = store.loadRules()
        self.dispatcher = dispatcher
        self.publisher = Publisher(session: session)
        self.session = session
        self.timing = timing
        self.catchUpDebounce = catchUpDebounce
        self.now = now
        dispatcher.rules.rules = rules.rules
        plugins = PluginManager(bundledDirectory: bundledPlugins, installedDirectory: store.pluginsDirectory, appVersion: appVersion,
                                registry: dispatcher.rules.registry, host: self)
        reloadPlugins()
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
        saveState()
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

    public func updateRules(_ change: (inout [Rule]) -> Void) throws {
        var r = rules
        change(&r.rules)
        try store.saveRules(r)
        rules = r
        dispatcher.rules.rules = r.rules
    }

    /// After "Edit config file…" / "Edit rules file…": re-read both files from disk.
    public func reloadFromDisk() {
        config = store.loadConfig()
        rules = store.loadRules()
        dispatcher.rules.rules = rules.rules
        reloadPlugins()
        applyStreams()
    }

    // MARK: plugins

    public func reloadPlugins() {
        plugins.reload(config: config)
        pluginPackages = plugins.packages
    }

    public func pluginName(_ id: String) -> String { plugins.package(id)?.manifest?.name ?? id }

    /// The user agreed to everything the manifest declares, for this exact source.
    public func consent(to package: PluginManager.Package) throws {
        guard let m = package.manifest else { return }
        try update { c in
            c.plugins.grants[m.id] = PluginGrant(permissions: m.permissions, consented: m.permissions, source: package.source.key)
            c.plugins.disabledIds.removeAll { $0 == m.id }
        }
        reloadPlugins()
    }

    /// Per-permission switch; revoking rebuilds the plugin's context without that method.
    public func setPermission(_ permission: Permission, pluginId: String, granted: Bool) throws {
        try update { c in
            guard var g = c.plugins.grants[pluginId] else { return }
            g.permissions.removeAll { $0 == permission.rawValue }
            if granted, g.consented.contains(permission.rawValue) { g.permissions.append(permission.rawValue) }
            c.plugins.grants[pluginId] = g
        }
        reloadPlugins()
    }

    public func setPluginEnabled(_ id: String, _ enabled: Bool) throws {
        try update { c in
            c.plugins.disabledIds.removeAll { $0 == id }
            if !enabled { c.plugins.disabledIds.append(id) }
        }
        reloadPlugins()
    }

    /// Installed (marketplace) packages only; bundled ones are disabled instead.
    public func uninstallPlugin(_ id: String) throws {
        guard PluginManifest.isValidId(id) else { return }
        try? FileManager.default.removeItem(at: store.pluginsDirectory.appendingPathComponent(id, isDirectory: true))
        try? FileManager.default.removeItem(at: store.pluginDataDirectory.appendingPathComponent(id + ".json"))
        try update { c in
            c.plugins.grants[id] = nil
            c.plugins.installedFrom[id] = nil
            c.plugins.disabledIds.removeAll { $0 == id }
        }
        reloadPlugins()
    }

    /// Why a marketplace entry may not be installed here, or nil. An id that is bundled, loaded from
    /// a local folder, or installed from a different marketplace can't be replaced from this one —
    /// otherwise any added marketplace could take over a trusted plugin with an "update".
    public func installConflict(id: String, marketplaceURL: String) -> String? {
        for pkg in pluginPackages where pkg.id == id && pkg.manifest != nil {
            switch pkg.source {
            case .bundled: return "Bundled with NtfyBar"
            case .local: return "Conflicts with a plugin in a local folder"
            case .installed:
                let from = config.plugins.installedFrom[id] ?? ""
                if from != marketplaceURL {
                    return "Conflicts with the installed copy from " + (URL(string: from)?.host() ?? "another marketplace")
                }
            }
        }
        if id.hasPrefix("com.ntfybar."), marketplaceURL != PluginSettings.officialMarketplace {
            return "com.ntfybar.* plugins come only from the official marketplace"
        }
        return nil
    }

    /// Writes a verified marketplace package and records the user's consent in one go.
    public func install(_ prepared: PreparedInstall) throws {
        if let conflict = installConflict(id: prepared.manifest.id, marketplaceURL: prepared.marketplaceURL) {
            throw MarketplaceError.invalidEntry(conflict)
        }
        try Marketplace.commit(prepared, into: store.pluginsDirectory)
        let m = prepared.manifest
        try update { c in
            c.plugins.installedFrom[m.id] = prepared.marketplaceURL
            c.plugins.grants[m.id] = PluginGrant(permissions: m.permissions, consented: m.permissions,
                                                 source: PluginManager.Source.installed.key)
            c.plugins.disabledIds.removeAll { $0 == m.id }
        }
        reloadPlugins()
    }

    /// A plugin popup button was pressed: call the plugin's onPopupAction with the message that
    /// triggered the popup. Unknown plugin/message → close.
    public func pluginPopupAction(_ ref: PopupContent.PluginRef, buttonId: String, topicId: UUID?, messageId: String?) -> PopupActionResult {
        guard let runtime = plugins.runtime(ref.pluginId), let topicId, let messageId,
              let topic = config.topic(topicId), let m = history.message(topicId: topicId, id: messageId) else { return .close }
        do {
            return try runtime.popupAction(ctx: ProviderContext(message: m, topic: topic, config: config), buttonId: buttonId, state: ref.state)
        } catch {
            Log.plugins.error("\(ref.pluginId, privacy: .public) onPopupAction: \(String(describing: error), privacy: .public)")
            return .close
        }
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

    // MARK: publishing

    /// Publishes to one of the user's topics. Quiet hours cap the priority; `rateKey` groups
    /// publishes for the 10-per-minute limit ("rules", a plugin id, …; nil = not limited).
    @discardableResult
    public func publish(_ req: PublishRequest, rateKey: String?) async throws -> String? {
        guard let topic = config.topic(req.topicId), let server = config.server(topic.serverId),
              TopicConfig.isValidTopicName(topic.topic) else { throw PublishError.unknownTopic }
        if let rateKey, !publishLimiter.allow(rateKey, at: now()) {
            Log.publish.error("publish rate limit hit (\(rateKey, privacy: .public))")
            throw PublishError.rateLimited
        }
        let priority = config.quietHours.cap(req.priority, at: now())
        let signature = Self.signature(topicId: req.topicId, title: req.title, message: req.message)
        pruneOwn()
        ownPending[signature] = now()
        do {
            let id = try await publisher.publish(req, server: server, topic: topic.topic, priority: priority)
            // The POST returned: from now on only the exact id counts as our echo. An echo that
            // raced ahead already consumed the signature.
            ownPending[signature] = nil
            if let id { ownIds["\(req.topicId.uuidString)/\(id)"] = now() }
            pruneOwn()
            return id
        } catch {
            ownPending[signature] = nil
            Log.publish.error("publish failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private static func signature(topicId: UUID, title: String?, message: String) -> String {
        "\(topicId.uuidString)\u{1F}\(title ?? "")\u{1F}\(message)"
    }

    /// Bounded: entries live 2 minutes, at most 1000 ids.
    private func pruneOwn() {
        let cutoff = now().addingTimeInterval(-120)
        ownIds = ownIds.filter { $0.value > cutoff }
        ownPending = ownPending.filter { $0.value > cutoff }
        if ownIds.count > 1000 {
            ownIds = Dictionary(uniqueKeysWithValues: ownIds.sorted { $0.value > $1.value }.prefix(1000).map { ($0.key, $0.value) })
        }
    }

    var ownEchoCount: Int { ownIds.count + ownPending.count }

    private func isOwnEcho(_ m: Message) -> Bool {
        pruneOwn()
        if ownIds.removeValue(forKey: "\(m.topicId.uuidString)/\(m.ntfy.id)") != nil { return true }
        let sig = Self.signature(topicId: m.topicId, title: m.title, message: m.body)
        return ownPending.removeValue(forKey: sig) != nil
    }

    // MARK: commands

    /// Queues a user-authored command (serial per topic). `onFailure` gets a one-line reason.
    public func runCommand(_ settings: CommandSettings, message m: Message, onFailure: @escaping @MainActor (String) -> Void) {
        guard let topic = config.topic(m.topicId) else { return }
        commands.enqueue(CommandQueue.Job(topicId: m.topicId, run: {
            await CommandRunner.run(settings, message: m, topic: topic)
        }, onDone: { result in
            Log.command.info("command exit \(result.exitCode, privacy: .public)\(result.timedOut ? " (timed out)" : "", privacy: .public) stdout: \(result.stdout, privacy: .private) stderr: \(result.stderr, privacy: .private)")
            if !result.succeeded && settings.notifyOnFailure {
                onFailure(result.timedOut ? "timed out after \(settings.timeoutSec) s" : "exit code \(result.exitCode)")
            }
        }))
    }

    public func runShortcut(name: String, message m: Message, onFailure: @escaping @MainActor (String) -> Void) {
        commands.enqueue(CommandQueue.Job(topicId: m.topicId, run: {
            await CommandRunner.runShortcut(name: name, message: m)
        }, onDone: { result in
            if !result.succeeded { onFailure("Shortcut \"\(name)\" failed (exit \(result.exitCode))") }
        }))
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
        let result = history.insert(m)
        // The cursor moves only once the message is safely stored (or already was): a failed
        // insert must be replayed by the next `since=`.
        guard result != .failed else {
            Log.history.error("could not store a message; it will be fetched again on reconnect")
            return
        }
        advanceCursor(serverId: serverId, time: r.message.time)
        guard result == .inserted else { return }  // replay of a message we already have
        if let topic = config.topic(m.topicId) {
            history.purge(topicId: topic.id, keep: topic.retention.count, days: topic.retention.days, now: now())
        }
        if isOwnEcho(m) {
            // Our own publish coming back: keep it in history, read, but run nothing (no loops).
            history.markRead(topicId: m.topicId, id: m.ntfy.id)
            refreshCounters()
            return
        }
        refreshCounters()
        let effects = dispatcher.handle(m, config: config, now: now())
        if !effects.isEmpty { onEffects?(effects) }
        if dispatcher.hasPendingCatchUp { scheduleCatchUpFlush() }
    }

    @ObservationIgnored private var stateSaveTask: Task<Void, Never>?

    private func advanceCursor(serverId: UUID, time: Int64) {
        streams[serverId]?.advanceCursor(to: time)
        let key = serverId.uuidString
        guard time > state.lastEventTime[key] ?? 0 else { return }
        state.lastEventTime[key] = time
        // Debounced: a 500-message replay must not mean 500 file writes.
        guard stateSaveTask == nil else { return }
        stateSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.saveState()
        }
    }

    public func saveState() {
        stateSaveTask?.cancel()
        stateSaveTask = nil
        do { try store.saveState(state) } catch { Log.config.error("state.json: \(error.localizedDescription, privacy: .public)") }
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

extension Engine: PluginHost {
    public var pluginDataDirectory: URL { store.pluginDataDirectory }

    public func isGranted(_ pluginId: String, _ permission: Permission) -> Bool {
        guard let pkg = plugins?.package(pluginId), pkg.state == .active, let m = pkg.manifest else { return false }
        return PluginManager.effectivePermissions(m, source: pkg.source, config: config).contains(permission)
    }

    public func history(topicId: UUID, before: Int64?, after: Int64?, limit: Int) -> [Message] {
        if let before { return history.older(topicId: topicId, before: before, limit: limit) }
        if let after { return history.newer(topicId: topicId, after: after, limit: limit) }
        return history.recent(topicId: topicId, limit: limit)
    }

    /// Fire-and-forget; the 10-per-minute limit is per plugin, quiet hours and the loop guard apply.
    public func publish(pluginId: String, _ request: PublishRequest) {
        Task { try? await self.publish(request, rateKey: pluginId) }
    }

    public func copy(_ text: String) { onCopy?(text) }
    /// Paused = no browser windows popping up, same as the openURL rule action.
    public func open(_ url: URL) {
        guard SafeOpen.isAllowed(url), !config.isPaused(at: now()) else { return }
        onOpen?(url)
    }
}
