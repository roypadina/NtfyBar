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

@Suite("Publish to a topic")
@MainActor
final class SendTests {
    let host = uniqueHost()
    let topic = "ntfybar-\(UUID().uuidString.prefix(10).lowercased())"
    let topicId = UUID()
    var effects: [Effect] = []

    let base = PublishRequest(topicId: UUID(), title: "T", message: "", priority: 3, tags: ["ntfybar-mac"])

    func one(_ item: Outgoing) throws -> PublishRequest {
        try #require(try Outgoing.requests([item], base: base).first)
    }

    func file(_ name: String, size: Int) throws -> URL {
        let url = tempDir().appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(size))  // sparse: no real disk use
        try h.close()
        return url
    }

    @Test func shortTextIsJSONWithCopyButton() async throws {
        let r = try one(.text("hello"))
        #expect(r.file == nil && r.copyButton && r.message == "hello")
        StubProtocol.register(host) { _, _ in [.status(200), .line(#"{"id":"j1"}"#), .end] }
        let id = try await Publisher(session: StubProtocol.session()).publish(r, server: ServerConfig(url: "https://\(host)"), topic: topic, priority: 3)
        #expect(id == "j1")
        let sent = try #require(StubProtocol.bodies(host).first)
        let b = try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        let actions = try #require(b["actions"] as? [[String: String]])
        #expect(actions == [["action": "copy", "label": "Copy", "value": "hello"]])
        #expect(b["tags"] as? [String] == ["ntfybar-mac"])
    }

    /// Bytes, not characters: Hebrew letters are 2 bytes in UTF-8.
    @Test func textThresholdsCountUTF8Bytes() throws {
        let copy = try one(.text(String(repeating: "א", count: 1000)))  // 2000 B
        #expect(copy.file == nil && copy.copyButton)
        let noCopy = try one(.text(String(repeating: "א", count: 1001)))  // 2002 B
        #expect(noCopy.file == nil && !noCopy.copyButton)
        let json = try one(.text(String(repeating: "a", count: 4000)))
        #expect(json.file == nil && !json.copyButton)
        #expect(Publisher.body(json, topic: topic, priority: 3)["actions"] == nil)
        let long = String(repeating: "ab", count: 2000) + "c"  // 4001 B
        let put = try one(.text(long))
        #expect(put.file == PublishFile(name: "clip.txt", data: Data(long.utf8)))
        #expect(put.message == String(long.prefix(80)) + "…" && !put.copyButton)
    }

    @Test func longTextIsPutAsClipTxtWithPriorityAndAuth() async throws {
        let long = String(repeating: "x", count: 5000)
        StubProtocol.register(host) { _, _ in [.status(200), .line(#"{"id":"p1"}"#), .end] }
        let id = try await Publisher(session: StubProtocol.session()).publish(
            try one(.text(long)), server: ServerConfig(url: "https://\(host)", auth: .token("tk_fake")), topic: topic, priority: 4)
        #expect(id == "p1")
        let req = try #require(StubProtocol.requests(host).first)
        #expect(req.httpMethod == "PUT" && req.url?.path == "/\(topic)")
        #expect(req.value(forHTTPHeaderField: "X-Priority") == "4")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tk_fake")
        #expect(StubProtocol.bodies(host).first == Data(long.utf8))
        let q = URLComponents(url: try #require(req.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(q.first { $0.name == "filename" }?.value == "clip.txt")
        #expect(q.first { $0.name == "message" }?.value == String(repeating: "x", count: 80) + "…")
    }

    @Test func queryParamsAreUTF8AndGoSafe() throws {
        var r = base
        r.title = "שלום 👋 C++; a&b=c"
        r.tags = ["ntfybar-mac", "עבודה"]
        r.message = "דוח 2026.pdf"
        let url = try #require(Publisher.fileURL(r, file: PublishFile(name: "דוח 2026.pdf", data: Data()),
                                                 base: URL(string: "https://ntfy.example")!, topic: "example-topic"))
        let raw = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        #expect(!raw.contains("+") && !raw.contains(";") && !raw.contains(" "), "Go reads + as space and drops ; pairs")
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(q == ["filename": "דוח 2026.pdf", "title": "שלום 👋 C++; a&b=c", "tags": "ntfybar-mac,עבודה", "message": "דוח 2026.pdf"])
        #expect(url.path == "/example-topic")
    }

    @Test func fileAndImageBecomeAttachments() throws {
        let url = tempDir().appendingPathComponent("report.pdf")
        try Data("%PDF-1.4".utf8).write(to: url)
        let f = try one(.file(url))
        #expect(f.file == PublishFile(name: "report.pdf", data: Data("%PDF-1.4".utf8)) && f.message == "report.pdf")
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let i = try one(.image(png))
        #expect(i.file == PublishFile(name: "clip.png", data: png) && i.message == "clip.png" && !i.copyButton)
    }

    @Test func fileSizeLimitIsCheckedBeforeUpload() throws {
        #expect(try one(.file(file("exact.bin", size: Outgoing.maxFileBytes))).file?.data.count == Outgoing.maxFileBytes)
        #expect(throws: PublishError.fileTooLarge("big.bin")) { try self.one(.file(self.file("big.bin", size: Outgoing.maxFileBytes + 1))) }
        #expect(throws: PublishError.unreadableFile("missing.txt")) { try self.one(.file(URL(fileURLWithPath: "/nonexistent/missing.txt"))) }
        let dir = tempDir()
        #expect(throws: PublishError.unreadableFile(dir.lastPathComponent)) { try self.one(.file(dir)) }
    }

    @Test func atMostTwentyFilesPerSend() throws {
        let url = tempDir().appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: url)
        let twenty = Array(repeating: Outgoing.file(url), count: 20)
        #expect(try Outgoing.requests([.text("first")] + twenty, base: base).count == 21, "text doesn't count")
        #expect(throws: PublishError.tooManyFiles) { try Outgoing.requests(twenty + [.image(Data([1]))], base: self.base) }
    }

    @Test func errorReasons() {
        #expect(PublishError.http(401).reason == "not allowed on this topic")
        #expect(PublishError.http(403).reason == "not allowed on this topic")
        #expect(PublishError.http(413).reason == "too large for the server")
        #expect(PublishError.http(500).reason == "HTTP 500")
        #expect(PublishError.transport("offline").reason == "server unreachable")
        #expect(PublishError.fileTooLarge("a.mov").reason == "“a.mov” is over 100 MB")
    }

    func engine(_ configure: (inout TopicConfig) -> Void = { _ in }) throws -> Engine {
        let store = ConfigStore(directory: tempDir())
        var c = Config()
        c.servers = [ServerConfig(url: "https://\(host)", auth: .token("tk_fake"))]
        var t = TopicConfig(id: topicId, serverId: c.servers[0].id, topic: topic, label: "Clipboard")
        configure(&t)
        c.topics = [t]
        try store.saveConfig(c)
        let e = try Engine(store: store, session: StubProtocol.session())
        e.onEffects = { [weak self] in self?.effects += $0 }
        return e
    }

    @Test func sendPutsSenderTagFirstIsNotRateLimitedAndRemembersTopic() async throws {
        StubProtocol.register(host) { _, _ in [.status(200), .line(#"{"id":"s"}"#), .end] }
        let e = try engine()
        defer { e.stop() }  // saving lastTopicId applies the config, which opens the stream
        for _ in 0..<6 { try await e.send([.text("a"), .text("b")], topicId: topicId, title: "", tags: [" work ", ""], priority: 0) }
        let sent = try #require(StubProtocol.bodies(host).first)
        let b = try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(b["tags"] as? [String] == ["ntfybar-mac", "work"])
        #expect(b["title"] == nil && b["priority"] as? Int == 1, "clamped to 1…5")
        #expect(StubProtocol.requests(host).filter { $0.httpMethod == "POST" }.count == 12,
                "12 sends in a row: the 10/min limit is for rules and plugins")
        #expect(e.config.publish.lastTopicId == topicId)
        #expect(e.store.loadConfig().publish.lastTopicId == topicId)
    }

    /// The loop guard covers file sends: the PUT's id (or, if the echo wins, title + file name).
    @Test(arguments: [false, true])
    func ownFileEchoRunsNothing(echoFirst: Bool) async throws {
        let t0 = Int64(Date().timeIntervalSince1970)
        let h = host
        let attachment: [String: Any] = ["name": "a.txt", "url": "https://\(h)/file/f1.txt", "type": "text/plain", "size": 1]
        let echo = ntfyLine(id: "f1", time: t0, topic: topic, title: "Mac", message: "a.txt", extra: ["attachment": attachment])
        StubProtocol.register(host) { [topic] req, _ in
            if req.httpMethod == "PUT" {
                return echoFirst ? [.delay(0.6), .status(200), .line(#"{"id":"f1"}"#), .end] : [.status(200), .line(#"{"id":"f1"}"#), .end]
            }
            return [.status(200), .line(openLine(time: t0, topic: topic)),
                    .until { StubProtocol.requests(h).contains { $0.httpMethod == "PUT" } },
                    .delay(echoFirst ? 0 : 0.3),
                    .line(echo),
                    .line(ntfyLine(id: "other", time: t0, topic: topic, title: "Mac", message: "not ours"))]
        }
        let e = try engine()
        e.start()
        defer { e.stop() }
        #expect(await eventually { e.streamStates.values.first == .connected })
        let url = tempDir().appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: url)
        try await e.send([.file(url)], topicId: topicId, title: "Mac", tags: [], priority: 3)
        #expect(await eventually { e.history.count() == 2 })
        let notified = effects.compactMap { if case let .notify(m, _) = $0 { m.ntfy.id } else { nil } }
        #expect(notified == ["other"])
        #expect(e.history.message(topicId: topicId, id: "f1")?.read == true)
    }

    @Test func textClipRule() {
        func a(_ name: String?, _ type: String? = "text/plain; charset=utf-8", size: Int64? = 100) -> NtfyAttachment {
            NtfyAttachment(name: name, url: "https://ntfy.example/file/x.txt", type: type, size: size)
        }
        #expect(AttachmentFile.isTextClip(a("clip.txt")))
        #expect(AttachmentFile.isTextClip(a("attachment.txt", "text/plain")))
        #expect(AttachmentFile.isTextClip(a("clip.txt", size: 1024 * 1024)))
        #expect(!AttachmentFile.isTextClip(a("clip.txt", size: 1024 * 1024 + 1)))
        #expect(!AttachmentFile.isTextClip(a("notes.txt")), "any other .txt stays a file")
        #expect(!AttachmentFile.isTextClip(a("clip.txt", "image/png")))
        #expect(!AttachmentFile.isTextClip(a("clip.txt", nil)))
        #expect(!AttachmentFile.isTextClip(a("clip.txt", size: nil)))
        #expect(!AttachmentFile.isTextClip(nil))
    }

    /// A long text arriving as clip.txt is copied as its text (not as a file); notes.txt stays a file.
    @Test(arguments: ["clip.txt", "notes.txt"])
    func textClipIsCopiedAsText(name: String) async throws {
        let t0 = Int64(Date().timeIntervalSince1970)
        let full = String(repeating: "שלום ", count: 1000)
        let attachment: [String: Any] = ["name": name, "url": "https://\(host)/file/m1.txt", "type": "text/plain; charset=utf-8",
                                         "size": full.utf8.count]
        let line = ntfyLine(id: "m1", time: t0, topic: topic, message: "שלום שלום…", extra: ["attachment": attachment])
        StubProtocol.register(host) { [topic] req, _ in
            if req.url?.path == "/file/m1.txt" {
                return req.value(forHTTPHeaderField: "Authorization") == "Bearer tk_fake" ? [.status(200), .data(Data(full.utf8)), .end] : [.status(403), .end]
            }
            return [.status(200), .line(openLine(time: t0, topic: topic)),
                    .line(line)]
        }
        let e = try engine { t in
            t.copyToClipboard = true
            t.downloadAttachments = true
            t.copyAttachment = true
        }
        e.start()
        defer { e.stop() }
        #expect(await eventually { !self.effects.isEmpty })
        let copied = effects.compactMap { if case let .copy(s) = $0 { s } else { nil } }
        let files = effects.filter { if case .attachment = $0 { true } else { false } }
        if name == "clip.txt" {
            #expect(copied == [full] && files.isEmpty)
            #expect(effects.contains { if case let .notify(m, _) = $0 { m.body == full } else { false } }, "shown as its text")
        } else {
            #expect(copied == ["שלום שלום…"] && files.count == 1)
        }
    }
}

@Suite("Publish settings")
struct PublishSettingsTests {
    @Test func defaultsTolerantDecodeAndRoundTrip() throws {
        let d = Config()
        #expect(d.publish.deviceTag == "ntfybar-mac" && d.publish.title == PublishSettings.computerName && d.publish.lastTopicId == nil)
        #expect(try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).publish == PublishSettings(), "old config.json")
        let id = UUID()
        let odd = try JSONDecoder().decode(Config.self, from: Data(#"{"publish":{"deviceTag":5,"title":"Desk","lastTopicId":"\#(id.uuidString)","x":1}}"#.utf8))
        #expect(odd.publish.deviceTag == "ntfybar-mac" && odd.publish.title == "Desk" && odd.publish.lastTopicId == id)
        let junk = try JSONDecoder().decode(Config.self, from: Data(#"{"publish":"yes","launchAtLogin":false}"#.utf8))
        #expect(junk.publish == PublishSettings() && !junk.launchAtLogin, "a bad publish block never wipes the rest")
        var c = Config()
        c.publish.lastTopicId = id
        c.publish.title = "My Mac"
        #expect(try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c)).publish == c.publish)
    }
}
