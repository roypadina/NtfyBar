import Foundation
import Testing
@testable import NtfyBarCore

/// End-to-end: Engine → NtfyStream → stubbed HTTP → history → dispatcher → effects.
@Suite("Engine + stream")
@MainActor
final class EngineStreamTests {
    let host = uniqueHost()
    let topic = "ntfybar-\(UUID().uuidString.prefix(10).lowercased())"
    let topicId = UUID()
    /// Recent server time: 1970-style times would be purged at once by the 30-day retention.
    let t0 = Int64(Date().timeIntervalSince1970) - 1000
    var effects: [Effect] = []

    func engine(auth: ServerAuth = .none, keepalive: Double = 90, configure: (inout Config) -> Void = { _ in }) throws -> Engine {
        let store = ConfigStore(directory: tempDir())
        var c = Config()
        c.servers = [ServerConfig(url: "https://\(host)", auth: auth)]
        c.topics = [TopicConfig(id: topicId, serverId: c.servers[0].id, topic: topic, label: "Demo")]
        configure(&c)
        try store.saveConfig(c)
        let e = try Engine(store: store, session: StubProtocol.session(),
                           timing: .init(keepaliveTimeout: keepalive, watchdogInterval: 0.05, backoff: Backoff(base: 0.05, cap: 0.2)),
                           catchUpDebounce: 0.2)
        e.onEffects = { [weak self] in self?.effects += $0 }
        return e
    }

    var notified: [String] {
        effects.compactMap { if case let .notify(m, _) = $0 { m.ntfy.id } else { nil } }
    }

    @Test func receivesLiveMessageAndNotifies() async throws {
        StubProtocol.register(host) { [topic, t0] _, _ in
            [.status(200), .line(openLine(time: t0, topic: topic)), .line(ntfyLine(id: "m1", time: t0, topic: topic, title: "Hi"))]
        }
        let e = try engine()
        e.start()
        defer { e.stop() }
        #expect(await eventually { self.notified == ["m1"] })
        #expect(e.unreadCount == 1)
        #expect(e.recent.first?.ntfy.title == "Hi")
        #expect(e.streamStates.values.first == .connected)
        let req = try #require(StubProtocol.requests(host).first)
        #expect(req.url?.path == "/\(topic)/json")
        #expect(req.url?.query == nil, "first-ever connect has no since")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test(arguments: [ServerAuth.basic(user: "testuser", pass: "fakepassword"), .token("tk_fake")])
    func sendsAuthHeader(_ auth: ServerAuth) async throws {
        StubProtocol.register(host) { [topic] _, _ in [.status(200), .line(openLine(time: 1, topic: topic))] }
        let e = try engine(auth: auth)
        e.start()
        defer { e.stop() }
        #expect(await eventually { !StubProtocol.requests(self.host).isEmpty })
        #expect(StubProtocol.requests(host)[safe: 0]?.value(forHTTPHeaderField: "Authorization") == auth.headerValue)
    }

    @Test(arguments: [401, 403])
    func authFailureStopsReconnecting(_ status: Int) async throws {
        StubProtocol.register(host) { _, _ in [.status(status), .end] }
        let e = try engine()
        e.start()
        defer { e.stop() }
        #expect(await eventually { e.streamStates.values.first == .authFailed(status: status) })
        try await Task.sleep(for: .milliseconds(400))
        e.reconnectAll()
        try await Task.sleep(for: .milliseconds(300))
        #expect(StubProtocol.requests(host).count == 1, "no retries, not even on wake/network change")
    }

    @Test func reconnectAsksSinceLastMessageAndDedupes() async throws {
        StubProtocol.register(host) { [topic, t0] _, attempt in
            if attempt == 0 {
                return [.status(200), .line(openLine(time: t0, topic: topic)),
                        .line(ntfyLine(id: "m1", time: t0, topic: topic)), .delay(0.05), .end]
            }
            // The server replays m1 (time >= since) plus one missed message, then a live one.
            return [.status(200), .line(openLine(time: t0 + 100, topic: topic)),
                    .line(ntfyLine(id: "m1", time: t0, topic: topic)),
                    .line(ntfyLine(id: "m2", time: t0 + 50, topic: topic)),
                    .line(ntfyLine(id: "m3", time: t0 + 100, topic: topic))]
        }
        let e = try engine()
        e.start()
        defer { e.stop() }
        #expect(await eventually { self.notified == ["m1", "m3"] })
        let second = try #require(StubProtocol.requests(host)[safe: 1])
        #expect(second.url?.query == "since=\(t0)")
        #expect(e.history.count() == 3, "m1 stored once")
        // m2 was replayed → catch-up summary instead of its own notification.
        #expect(await eventually {
            self.effects.contains(.summaryNotification(topicId: self.topicId, label: "Demo", count: 1))
        })
        #expect(e.recent.contains { $0.ntfy.id == "m2" && $0.isCatchUp })
        e.saveState()  // state.json writes are debounced
        #expect(e.store.loadState().lastEventTime.values.first == t0 + 100)
    }

    @Test func sinceSurvivesRestartAndCatchUpIgnoresLocalClock() async throws {
        let dir = tempDir()
        StubProtocol.register(host) { [topic] _, _ in
            [.status(200), .line(openLine(time: 500, topic: topic)), .line(ntfyLine(id: "old", time: 400, topic: topic))]
        }
        let store = ConfigStore(directory: dir)
        var c = Config()
        c.servers = [ServerConfig(url: "https://\(host)")]
        c.topics = [TopicConfig(id: topicId, serverId: c.servers[0].id, topic: topic, label: "Demo")]
        try store.saveConfig(c)
        var s = StreamState()
        s.lastEventTime[c.servers[0].id.uuidString] = 300
        try store.saveState(s)
        // Local clock 5 minutes behind the server: classification must not care.
        let e = try Engine(store: store, session: StubProtocol.session(), catchUpDebounce: 0.1,
                           now: { Date(timeIntervalSince1970: 100) })
        e.onEffects = { [weak self] in self?.effects += $0 }
        e.start()
        defer { e.stop() }
        #expect(await eventually { e.recent.first?.ntfy.id == "old" })
        #expect(StubProtocol.requests(host)[safe: 0]?.url?.query == "since=300")
        #expect(e.recent.first?.isCatchUp == true)
        #expect(notified.isEmpty)
    }

    @Test func keepaliveTimeoutReconnects() async throws {
        StubProtocol.register(host) { [topic] _, attempt in
            attempt == 0 ? [.status(200), .line(openLine(time: 1, topic: topic))]  // then silence, never ends
                         : [.status(200), .line(openLine(time: 2, topic: topic)), .line(ntfyLine(id: "after", time: 2, topic: topic))]
        }
        let e = try engine(keepalive: 0.3)
        e.start()
        defer { e.stop() }
        #expect(await eventually(timeout: 4) { self.notified == ["after"] })
    }

    @Test func duplicateDeliveryProducesNoSecondEffect() async throws {
        StubProtocol.register(host) { [topic, t0] _, _ in
            [.status(200), .line(openLine(time: t0, topic: topic)),
             .line(ntfyLine(id: "d1", time: t0, topic: topic)), .line(ntfyLine(id: "d1", time: t0, topic: topic))]
        }
        let e = try engine()
        e.start()
        defer { e.stop() }
        #expect(await eventually { self.notified == ["d1"] })
        try await Task.sleep(for: .milliseconds(200))
        #expect(notified == ["d1"])
        #expect(e.unreadCount == 1)
    }

    @Test func redirectIsTerminalAndNotFollowed() async throws {
        let other = uniqueHost()
        StubProtocol.register(host) { _, _ in [.status(302, ["Location": "https://\(other)/x/json"]), .end] }
        StubProtocol.register(other) { _, _ in [.status(200)] }
        let e = try engine(auth: .token("tk_secret"))
        e.start()
        defer { e.stop() }
        #expect(await eventually { e.streamStates.values.first == .redirected(status: 302) })
        try await Task.sleep(for: .milliseconds(300))
        e.reconnectAll()
        try await Task.sleep(for: .milliseconds(200))
        #expect(StubProtocol.requests(host).count == 1, "no retry until the URL is fixed")
        #expect(StubProtocol.requests(other).isEmpty, "credentials never sent to the redirect target")
        #expect(StatusSummary.line(config: e.config, states: e.streamStates, now: Date()).contains("redirects"))
    }

    @Test func backoffResetsAfterEachOpenEvent() async throws {
        StubProtocol.register(host) { [topic] _, attempt in
            // Connections 0–2 open then end (backoff must reset); 3–4 fail before `open` (it must grow).
            attempt < 3 ? [.status(200), .line(openLine(time: 1, topic: topic)), .end] : [.status(500), .end]
        }
        var delays: [Double] = []
        let base = 0.05
        let stream = NtfyStream(serverId: UUID(), baseURL: URL(string: "https://\(host)")!, authHeader: nil, topics: [topic: topicId],
                                lastEventTime: nil, session: StubProtocol.session(),
                                timing: .init(keepaliveTimeout: 90, watchdogInterval: 1, backoff: Backoff(base: base, cap: 10)),
                                now: { Date(timeIntervalSince1970: 0) }, jitter: { 0 },
                                onMessage: { _ in }, onState: { state in
                                    if case let .reconnecting(at) = state { delays.append(at.timeIntervalSince1970) }
                                })
        stream.start()
        defer { stream.stop() }
        #expect(await eventually(timeout: 5) { delays.count >= 5 })
        let expected = [base, base, base, base * 2, base * 4]
        #expect(zip(delays, expected).allSatisfy { abs($0 - $1) < 1e-6 }, "\(delays)")
    }

    @Test func steadyMessagesKeepTheWatchdogQuiet() async throws {
        StubProtocol.register(host) { [topic, t0] _, attempt in
            guard attempt == 0 else { return [.status(200)] }
            var steps: [StubProtocol.Step] = [.status(200), .line(openLine(time: t0, topic: topic))]
            for i in 0..<10 { steps += [.delay(0.1), .line(ntfyLine(id: "s\(i)", time: t0, topic: topic))] }
            return steps
        }
        let e = try engine(keepalive: 0.3)
        e.start()
        defer { e.stop() }
        // Generous timeout: other suites run busy JavaScript on the main actor in parallel.
        #expect(await eventually(timeout: 8) { e.history.count() == 10 })
        #expect(StubProtocol.requests(host).count == 1, "messages count as activity, not only keepalives")
    }

    @Test func failedInsertDoesNotAdvanceTheCursor() async throws {
        let closed = Flag()
        StubProtocol.register(host) { [topic, t0] _, _ in
            [.status(200), .line(openLine(time: t0, topic: topic)), .until { closed.value },
             .line(ntfyLine(id: "lost", time: t0, topic: topic))]
        }
        let e = try engine()
        e.start()
        #expect(await eventually { e.streamStates.values.first == .connected })
        e.history.close()
        closed.set()
        try await Task.sleep(for: .milliseconds(600))
        e.stop()
        #expect(notified.isEmpty)
        #expect(e.store.loadState().lastEventTime.isEmpty, "the next since= will fetch it again")
    }

    @Test func addingATopicReconnectsWithSince() async throws {
        StubProtocol.register(host) { [topic, t0] _, attempt in
            attempt == 0 ? [.status(200), .line(openLine(time: t0, topic: topic)), .line(ntfyLine(id: "a1", time: t0, topic: topic))]
                         : [.status(200), .line(openLine(time: t0 + 5, topic: topic))]
        }
        let e = try engine()
        e.start()
        defer { e.stop() }
        #expect(await eventually { self.notified == ["a1"] })
        try e.update { c in c.topics.append(TopicConfig(serverId: c.servers[0].id, topic: "ntfybar-second-demo", label: "Second")) }
        #expect(await eventually { StubProtocol.requests(self.host).count == 2 })
        let second = try #require(StubProtocol.requests(host)[safe: 1])
        #expect(second.url?.query == "since=\(t0)")
        #expect(second.url?.path.contains("ntfybar-second-demo") == true)
    }

    @Test func reconnectNowCutsABackoffSleepShort() async throws {
        StubProtocol.register(host) { [topic] _, _ in [.status(200), .line(openLine(time: 1, topic: topic)), .end] }
        let store = ConfigStore(directory: tempDir())
        var c = Config()
        c.servers = [ServerConfig(url: "https://\(host)")]
        c.topics = [TopicConfig(id: topicId, serverId: c.servers[0].id, topic: topic, label: "Demo")]
        try store.saveConfig(c)
        let e = try Engine(store: store, session: StubProtocol.session(),
                           timing: .init(keepaliveTimeout: 90, watchdogInterval: 0.05, backoff: Backoff(base: 30, cap: 60)))
        e.start()
        defer { e.stop() }
        #expect(await eventually { if case .reconnecting = e.streamStates.values.first { true } else { false } })
        e.reconnectAll()
        #expect(await eventually(timeout: 5) { StubProtocol.requests(self.host).count == 2 })
    }

    @Test func sameTopicNameOnTwoServersStaysSeparate() async throws {
        let host2 = uniqueHost()
        let otherId = UUID()
        for h in [host, host2] {
            StubProtocol.register(h) { [topic, t0] _, _ in
                [.status(200), .line(openLine(time: t0, topic: topic)), .line(ntfyLine(id: "from-\(h)", time: t0, topic: topic))]
            }
        }
        let e = try engine { [host2, topic, otherId] c in
            let s2 = ServerConfig(url: "https://\(host2)")
            c.servers.append(s2)
            c.topics.append(TopicConfig(id: otherId, serverId: s2.id, topic: topic, label: "Other"))
        }
        e.start()
        defer { e.stop() }
        #expect(await eventually { e.history.count() == 2 })
        #expect(e.history.recent(topicId: topicId, limit: 5).map(\.ntfy.id) == ["from-\(host)"])
        #expect(e.history.recent(topicId: otherId, limit: 5).map(\.ntfy.id) == ["from-\(host2)"])
    }

    @Test func replacingATopicWithTheSameNameRebuildsTheStream() async throws {
        StubProtocol.register(host) { [topic] _, _ in [.status(200), .line(openLine(time: 1, topic: topic))] }
        let e = try engine()
        e.start()
        defer { e.stop() }
        #expect(await eventually { e.streamStates.values.first == .connected })
        try e.update { c in
            let old = c.topics.removeFirst()
            c.topics.append(TopicConfig(serverId: old.serverId, topic: old.topic, label: "New id"))
        }
        #expect(await eventually { StubProtocol.requests(self.host).count == 2 }, "new topicId → new stream")
    }

    @Test func messagesForUnconfiguredTopicsAreIgnored() async throws {
        StubProtocol.register(host) { [topic, t0] _, _ in
            [.status(200), .line(openLine(time: t0, topic: topic)),
             .line(ntfyLine(id: "x", time: t0, topic: "someone-elses")), .line(ntfyLine(id: "y", time: t0, topic: topic))]
        }
        let e = try engine()
        e.start()
        defer { e.stop() }
        #expect(await eventually { self.notified == ["y"] })
        #expect(e.history.count() == 1)
    }

    @Test func configEditRebuildsStreamAndClearsAuthFailure() async throws {
        StubProtocol.register(host) { [topic] req, _ in
            req.value(forHTTPHeaderField: "Authorization") == nil ? [.status(401), .end]
                : [.status(200), .line(openLine(time: 1, topic: topic))]
        }
        let e = try engine()
        e.start()
        defer { e.stop() }
        #expect(await eventually { e.streamStates.values.first == .authFailed(status: 401) })
        try e.update { $0.servers[0].auth = .token("tk_fixed") }
        #expect(await eventually { e.streamStates.values.first == .connected })
    }

    @Test func invalidTopicNameIsNeverSubscribed() async throws {
        StubProtocol.register(host) { _, _ in [.status(200)] }
        let e = try engine { $0.topics[0].topic = "a,b" }
        e.start()
        defer { e.stop() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(StubProtocol.requests(host).isEmpty)
        #expect(e.streamStates.isEmpty)
    }
}
