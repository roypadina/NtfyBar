import Foundation
import Testing
@testable import NtfyBarCore

@Suite("Quiet hours")
struct QuietHoursTests {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        return c
    }()

    func at(_ h: Int, _ m: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: h, minute: m))!
    }

    @Test func acrossMidnight() {
        let q = QuietHours()  // 20:00–09:00, max 4
        #expect(q.cap(5, at: at(21, 0), calendar: cal) == 4)
        #expect(q.cap(5, at: at(23, 59), calendar: cal) == 4)
        #expect(q.cap(5, at: at(0, 0), calendar: cal) == 4)
        #expect(q.cap(5, at: at(8, 59), calendar: cal) == 4)
        #expect(q.cap(5, at: at(9, 0), calendar: cal) == 5)
        #expect(q.cap(5, at: at(19, 59), calendar: cal) == 5)
        #expect(q.cap(5, at: at(20, 0), calendar: cal) == 4)
        #expect(q.cap(3, at: at(22, 0), calendar: cal) == 3, "lower priorities untouched")
    }

    @Test func sameDayWindowEmptyWindowDisabledAndJunk() {
        #expect(QuietHours(start: "13:00", end: "14:00", maxPriority: 2).cap(5, at: at(13, 30), calendar: cal) == 2)
        #expect(QuietHours(start: "13:00", end: "14:00", maxPriority: 2).cap(5, at: at(14, 0), calendar: cal) == 5)
        #expect(QuietHours(start: "10:00", end: "10:00").cap(5, at: at(10, 0), calendar: cal) == 5, "start == end = empty")
        #expect(QuietHours(enabled: false).cap(5, at: at(23, 0), calendar: cal) == 5)
        #expect(QuietHours(start: "25:00", end: "x").cap(5, at: at(23, 0), calendar: cal) == 5)
    }

    @Test func rateLimiter() {
        var r = RateLimiter(limit: 10, window: 60)
        let t = Date()
        var results: [Bool] = []
        for i in 0..<10 { results.append(r.allow("k", at: t.addingTimeInterval(Double(i)))) }
        results.append(r.allow("k", at: t.addingTimeInterval(10)))
        results.append(r.allow("other", at: t.addingTimeInterval(10)))
        results.append(r.allow("k", at: t.addingTimeInterval(61)))
        #expect(results == Array(repeating: true, count: 10) + [false, true, true])
    }
}

@Suite("Publishing")
@MainActor
final class PublishTests {
    let host = uniqueHost()
    let topic = "ntfybar-\(UUID().uuidString.prefix(10).lowercased())"
    let topicId = UUID()
    var effects: [Effect] = []

    func body(_ i: Int = 0) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: StubProtocol.bodies(host)[i]) as? [String: Any])
    }

    @Test func jsonBodyGoesToServerRootWithAuth() async throws {
        StubProtocol.register(host) { _, _ in [.status(200), .line(#"{"id":"new1","time":1,"event":"message","topic":"x"}"#), .end] }
        let server = ServerConfig(url: "https://\(host)", auth: .token("tk_fake"))
        let id = try await Publisher(session: StubProtocol.session()).publish(
            PublishRequest(topicId: topicId, title: "T", message: "M", priority: 4, tags: ["a"], click: "file:///etc/passwd"),
            server: server, topic: topic, priority: 4)
        #expect(id == "new1")
        let req = try #require(StubProtocol.requests(host).first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "" || req.url?.path == "/")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tk_fake")
        let b = try body()
        #expect(b["topic"] as? String == topic && b["title"] as? String == "T" && b["message"] as? String == "M")
        #expect(b["priority"] as? Int == 4 && b["tags"] as? [String] == ["a"])
        #expect(b["click"] == nil, "non-http click dropped")
    }

    @Test func non2xxThrowsAndRedirectIsNotFollowed() async throws {
        StubProtocol.register(host) { _, _ in [.status(302, ["Location": "https://elsewhere.example/"]), .end] }
        await #expect(throws: PublishError.http(302)) {
            try await Publisher(session: StubProtocol.session()).publish(PublishRequest(topicId: self.topicId, message: "x"),
                                                                         server: ServerConfig(url: "https://\(self.host)"), topic: self.topic, priority: 3)
        }
    }

    func engine(now: @escaping @Sendable () -> Date = { Date() }) throws -> Engine {
        let store = ConfigStore(directory: tempDir())
        var c = Config()
        c.servers = [ServerConfig(url: "https://\(host)")]
        c.topics = [TopicConfig(id: topicId, serverId: c.servers[0].id, topic: topic, label: "Demo")]
        try store.saveConfig(c)
        let e = try Engine(store: store, session: StubProtocol.session(), now: now)
        e.onEffects = { [weak self] in self?.effects += $0 }
        return e
    }

    @Test func quietHoursCapEngineEnginePublishes() async throws {
        StubProtocol.register(host) { _, _ in [.status(200), .line(#"{"id":"q1"}"#), .end] }
        var cal = Calendar.current
        cal.timeZone = .current
        let night = cal.date(bySettingHour: 23, minute: 0, second: 0, of: Date())!
        let e = try engine(now: { night })
        try await e.publish(PublishRequest(topicId: topicId, message: "late", priority: 5), rateKey: nil)
        #expect(try body()["priority"] as? Int == 4, "urgent capped to high at 23:00")
    }

    @Test func unknownTopicAndRateLimit() async throws {
        StubProtocol.register(host) { _, _ in [.status(200), .line(#"{"id":"r"}"#), .end] }
        let e = try engine()
        await #expect(throws: PublishError.unknownTopic) {
            try await e.publish(PublishRequest(topicId: UUID(), message: "x"), rateKey: nil)
        }
        for i in 0..<10 { try await e.publish(PublishRequest(topicId: topicId, message: "m\(i)"), rateKey: "rules") }
        await #expect(throws: PublishError.rateLimited) {
            try await e.publish(PublishRequest(topicId: self.topicId, message: "eleven"), rateKey: "rules")
        }
        try await e.publish(PublishRequest(topicId: topicId, message: "other key"), rateKey: "com.example.plugin")
    }

    /// Loop guard: our own publish echoing back on the stream is stored but triggers nothing —
    /// both when the POST returns first (id match) and when the echo wins the race (signature match).
    @Test(arguments: [false, true])
    func ownEchoRunsNothing(echoFirst: Bool) async throws {
        let t0 = Int64(Date().timeIntervalSince1970)
        let publishHost = host
        StubProtocol.register(host) { [topic] req, _ in
            if req.httpMethod == "POST" {
                return echoFirst ? [.delay(0.6), .status(200), .line(#"{"id":"echo1"}"#), .end]
                                 : [.status(200), .line(#"{"id":"echo1"}"#), .end]
            }
            // The echo goes out only once our POST reached the server: right away (beating the POST's
            // delayed response), or 0.3 s later (after the response).
            return [.status(200), .line(openLine(time: t0, topic: topic)),
                    .until { StubProtocol.requests(publishHost).contains { $0.httpMethod == "POST" } },
                    .delay(echoFirst ? 0 : 0.3),
                    .line(ntfyLine(id: "echo1", time: t0, topic: topic, title: "Re", message: "ack")),
                    .line(ntfyLine(id: "other", time: t0, topic: topic, title: "Re", message: "not ours"))]
        }
        let e = try engine()
        e.start()
        defer { e.stop() }
        #expect(await eventually { e.streamStates.values.first == .connected })
        try await e.publish(PublishRequest(topicId: topicId, title: "Re", message: "ack"), rateKey: "rules")
        #expect(await eventually { e.history.count() == 2 })
        let notified = effects.compactMap { if case let .notify(m, _) = $0 { m.ntfy.id } else { nil } }
        #expect(notified == ["other"])
        #expect(e.history.message(topicId: topicId, id: "echo1")?.read == true)
    }
}

@Suite("ntfy http actions")
struct HTTPActionTests {
    @Test func buildsExactlyTheDescribedRequest() throws {
        let a = NtfyAction(action: "http", label: "Ack", url: "https://hooks.example/ack", method: nil,
                           headers: ["X-Token": "abc"], body: "done")
        let r = try #require(HTTPAction.request(for: a))
        #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "X-Token") == "abc")
        #expect(r.value(forHTTPHeaderField: "Authorization") == nil, "server credentials never attached")
        #expect(r.httpBody == Data("done".utf8))
        let get = try #require(HTTPAction.request(for: NtfyAction(action: "http", label: "G", url: "https://hooks.example/g", method: "get", body: "x")))
        #expect(get.httpMethod == "GET" && get.httpBody == nil)
        #expect(HTTPAction.request(for: NtfyAction(action: "http", label: "F", url: "file:///etc/passwd")) == nil)
        #expect(HTTPAction.request(for: NtfyAction(action: "view", label: "V", url: "https://example.com")) == nil)
    }
}

@Suite("Review follow-ups")
@MainActor
final class ReviewFollowUpTests {
    let host = uniqueHost()
    let topic = "ntfybar-\(UUID().uuidString.prefix(10).lowercased())"
    let topicId = UUID()

    @Test func watchdogLimitIsCapped() {
        #expect(NtfyStream.watchdogLimit(keepaliveTimeout: 90, observedGap: 45) == 90)
        #expect(NtfyStream.watchdogLimit(keepaliveTimeout: 90, observedGap: 120) == 240)
        #expect(NtfyStream.watchdogLimit(keepaliveTimeout: 90, observedGap: 20 * 60) == 300, "one long sleep can't stretch it forever")
    }

    @Test func randomTopicIsLongAndValid() {
        let names = (0..<50).map { _ in TopicConfig.randomName() }
        #expect(names.allSatisfy { $0.range(of: #"^[-_A-Za-z0-9]{16,64}$"#, options: .regularExpression) != nil && TopicConfig.isValidTopicName($0) })
        #expect(Set(names).count == 50)
        #expect(names[0].count == "ntfybar-".count + 22)
    }

    @Test func quietHoursTimeField() {
        #expect(QuietHours.isValidTime("20:00") && QuietHours.isValidTime("9:00") && QuietHours.isValidTime("00:00"))
        #expect(!QuietHours.isValidTime("25:00") && !QuietHours.isValidTime("0900") && !QuietHours.isValidTime("9:60") && !QuietHours.isValidTime(""))
    }

    @Test func pathologicalRegexReturnsFast() throws {
        let text = String(repeating: "a", count: 8000) + "b"  // within the 8 KB that is searched
        let start = Date()
        #expect(throws: SafeRegex.Failure.tooSlow) { try SafeRegex.matches("(a+)+$", in: text) }
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(try SafeRegex.matches("^Backup (OK|FAILED)$", in: "Backup FAILED"))
        #expect(try !SafeRegex.matches("x", in: ""))
        #expect(throws: SafeRegex.Failure.invalidPattern) { try SafeRegex.matches("([", in: "x") }
        // Through a rule: too slow = no match, never a hang.
        var c = Config()
        c.topics = [TopicConfig(id: topicId, serverId: c.servers[0].id, topic: topic, label: "T")]
        let rule = Rule(name: "redos", conditions: [RuleStep("builtin.messageRegex", ["pattern": .string("(a+)+$")])],
                        actions: [RuleStep("builtin.copy")])
        let m = makeMessage(topicId: topicId, body: text)
        let t2 = Date()
        #expect(RuleEngine(rules: [rule]).evaluate(m, topic: c.topics[0], config: c).effects.isEmpty)
        #expect(Date().timeIntervalSince(t2) < 1)
    }

    @Test func shortcutInputFileIsPrivateAndRemoved() async throws {
        let script = tempDir().appendingPathComponent("fake-shortcuts")
        try Data("#!/bin/sh\nstat -f %Lp \"$4\"; echo \"$4\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let r = await CommandRunner.runShortcut(name: "x", message: makeMessage(topicId: topicId, body: "secret"), executable: script.path)
        let lines = r.stdout.split(separator: "\n").map(String.init)
        #expect(lines.first == "600")
        #expect(lines.count == 2 && !FileManager.default.fileExists(atPath: lines[1]))
    }

    @Test func maxSizedEnvironmentStillSpawns() async {
        let big = String(repeating: "x", count: 100_000)
        var t = TopicConfig(serverId: UUID(), topic: topic, label: big)
        t.id = topicId
        let n = NtfyMessage(id: "big", time: 1, topic: topic, title: big, message: big, tags: [big], click: big)
        let m = Message(topicId: topicId, ntfy: n, receivedAt: Date(), isCatchUp: false, raw: big)
        let r = await CommandRunner.run(CommandSettings(command: "printf %s \"${#NTFY_MESSAGE}\""), message: m, topic: t)
        #expect(r.succeeded, "\(r.stderr)")
        #expect(r.stdout == "65536")
    }

    @Test func pauseKeepsCopyAndPublishOnly() {
        var c = Config()
        c.topics = [TopicConfig(id: topicId, serverId: c.servers[0].id, topic: topic, label: "T")]
        c.pausedUntil = .distantFuture
        let rule = Rule(name: "all", conditions: [RuleStep("builtin.priority", ["value": .number(1)])], actions: [
            RuleStep("builtin.copy"), RuleStep("builtin.publish", ["topicId": .string(topicId.uuidString), "message": .string("x")]),
            RuleStep("builtin.openURL", ["template": .string("https://example.com")]), RuleStep("builtin.runShortcut", ["name": .string("S")]),
            RuleStep("builtin.runCommand", ["command": .string("true")]), RuleStep("builtin.playSound", ["name": .string("Glass")]),
            RuleStep("builtin.popup")])
        let effects = Dispatcher(rules: RuleEngine(rules: [rule])).handle(makeMessage(topicId: topicId), config: c, now: Date())
        #expect(effects.count == 2)
        #expect(effects.contains(.copy("hello")))
        #expect(effects.contains { if case .publish = $0 { true } else { false } })
    }

    @Test func loopGuardForgetsAfterThePostAndStaysBounded() async throws {
        StubProtocol.register(host) { req, _ in
            req.httpMethod == "POST" ? [.status(200), .line("{\"id\":\"p\(UUID().uuidString.prefix(8))\"}"), .end] : [.status(200)]
        }
        let store = ConfigStore(directory: tempDir())
        var c = Config()
        c.servers = [ServerConfig(url: "https://\(host)")]
        c.topics = [TopicConfig(id: topicId, serverId: c.servers[0].id, topic: topic, label: "T")]
        try store.saveConfig(c)
        let e = try Engine(store: store, session: StubProtocol.session())
        for i in 0..<1100 { try await e.publish(PublishRequest(topicId: topicId, message: "m\(i)"), rateKey: nil) }
        #expect(e.ownEchoCount <= 1000, "\(e.ownEchoCount)")
    }
}
