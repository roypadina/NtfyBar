import Foundation
import Testing
@testable import NtfyBarCore

/// v1.1: popup position/level, choice params, scheduled publish, and the new bundled plugins.
@Suite("Plugins v1.1")
@MainActor
struct PluginsV11Tests {
    let host = FakeHost()
    let registry = ProviderRegistry()

    func load(_ grants: [String: [String]]) -> PluginManager {
        for (id, perms) in grants {
            host.config.plugins.grants[id] = PluginGrant(permissions: perms, source: "bundled")
            host.grants[id] = Set(perms.compactMap(Permission.init(rawValue:)))
        }
        let m = PluginManager(bundledDirectory: bundledPluginsDir, installedDirectory: tempDir(), appVersion: "1.1.0", registry: registry, host: host)
        m.reload(config: host.config)
        return m
    }

    func msg(_ id: String, title: String? = "Disk full", body: String = "94%", priority: Int? = 4, time: Int64 = 1_700_000_000,
             tags: [String]? = nil) -> Message {
        makeMessage(topicId: host.triggerTopic.id, id: id, time: time, title: title, body: body, priority: priority, tags: tags)
    }

    func popup(_ out: ActionOutput) -> PluginPopupRequest? {
        if case let .pluginPopup(r)? = out.effects.first { return r }
        return nil
    }

    // MARK: runtime

    @Test func popupSpecPositionAndLevel() throws {
        let s = try PopupSpec.parse(JSONValue.parse(#"{"title":"x","position":"topRight","level":"overFullScreen"}"#)!)
        let c = s.content(key: "k", label: "L", pluginName: "P", topicId: nil, messageId: nil)
        #expect(c.position == .topRight && c.level == .overFullScreen)
        var d = PopupSettings()
        d.position = .topRight
        let inherit = try PopupSpec.parse(JSONValue.parse(#"{"title":"x"}"#)!).content(key: "k", label: "L", pluginName: "P",
                                                                                       topicId: nil, messageId: nil, defaults: d)
        #expect(inherit.position == .topRight, "no position → the topic's own setting")
        #expect(throws: PopupSpec.Invalid.self) { try PopupSpec.parse(JSONValue.parse(#"{"title":"x","position":"bottom"}"#)!) }
        #expect(throws: PopupSpec.Invalid.self) { try PopupSpec.parse(JSONValue.parse(#"{"title":"x","level":"top"}"#)!) }
    }

    @Test func choiceParamsForPlugins() throws {
        let base = try JSONDecoder().decode(PluginManifest.self, from: Data(ManifestTests.valid.utf8))
        var p = base.providers[0]
        p.params = [ParamSpec("pos", "Position", .choice, choices: ["topCenter", "topRight"])]
        #expect(base.providerErrors(p).isEmpty)
        for bad in [["only"], ["a", "a"], ["has space", "b"], Array(repeating: "x", count: 21).enumerated().map { "o\($0.offset)" }] {
            p.params = [ParamSpec("pos", "Position", .choice, choices: bad)]
            #expect(!base.providerErrors(p).isEmpty, "\(bad)")
        }
    }

    @Test func scheduledPublishBodyAndBridge() throws {
        let body = Publisher.body(PublishRequest(topicId: UUID(), message: "m", delay: 600), topic: "t", priority: 3)
        #expect(body["delay"] as? String == "600s")
        let r = try PluginRuntime(pluginId: "com.example.d", script: """
            function later(ctx) { return ntfy.publish({topicId: ctx.topic.id, message: 'x', delay: 600}); }
            function tooSoon(ctx) { return ntfy.publish({topicId: ctx.topic.id, message: 'x', delay: 5}); }
            """, granted: [.publish], host: host)
        host.grants["com.example.d"] = [.publish]
        #expect(try r.condition("later", ctx: host.ctx(), params: [:]))
        #expect(host.published.last?.1.delay == 600)
        #expect(throws: PluginError.self) { try r.condition("tooSoon", ctx: host.ctx(), params: [:]) }
    }

    // MARK: Alert Card

    @Test func alertCardShowsCardWithChoicesAndSnoozes() throws {
        let m = load(["com.ntfybar.alert-card": ["ui", "publish", "storage"]])
        #expect(m.package("com.ntfybar.alert-card")?.state == .active)
        let params: Params = ["timeoutSec": .number(30), "position": .string("topRight"), "level": .string("overFullScreen"),
                              "snoozeMin": .number(15), "countToday": .bool(true)]
        let req = try #require(popup(try registry.run("com.ntfybar.alert-card.show", host.ctx(msg("a1")), params)))
        #expect(req.spec.timeoutSec == 30 && req.spec.position == .topRight && req.spec.level == .overFullScreen)
        #expect(req.spec.accent == .warning)
        #expect(req.spec.buttons.map(\.id) == ["ack", "snooze"] && req.spec.buttons[0].style == .prominent)
        #expect(req.spec.buttons[1].label == "Snooze 15 min")
        // Urgent never auto-closes.
        let urgent = try #require(popup(try registry.run("com.ntfybar.alert-card.show", host.ctx(msg("a2", priority: 5)), params)))
        #expect(urgent.spec.timeoutSec == 0 && urgent.spec.accent == .critical)
        // Second arrival of the same title today → badge.
        let again = try #require(popup(try registry.run("com.ntfybar.alert-card.show", host.ctx(msg("a3", time: 1_700_000_100)), params)))
        #expect(again.spec.blocks.contains(.badge("3rd time today")))
        // Snooze → scheduled re-send tagged ntfybar-snoozed, then close.
        let result = try m.runtime("com.ntfybar.alert-card")!.popupAction(ctx: host.ctx(msg("a1")), buttonId: "snooze", state: req.spec.state)
        #expect(result == .close)
        let sent = try #require(host.published.last?.1)
        #expect(sent.delay == 900 && sent.tags.contains("ntfybar-snoozed") && sent.title == "Disk full" && sent.priority == 4)
        // The snoozed copy coming back shows its badge.
        let back = try #require(popup(try registry.run("com.ntfybar.alert-card.show", host.ctx(msg("a4", tags: ["ntfybar-snoozed"])), params)))
        #expect(back.spec.blocks.contains(.badge("Snoozed")))
        // Acknowledge just closes.
        #expect(try m.runtime("com.ntfybar.alert-card")!.popupAction(ctx: host.ctx(msg("a1")), buttonId: "ack", state: req.spec.state) == .close)
        #expect(host.published.count == 1)
    }

    @Test func alertCardWithoutPublishHasNoSnooze() throws {
        _ = load(["com.ntfybar.alert-card": ["ui"]])
        host.config.plugins.grants["com.ntfybar.alert-card"] = PluginGrant(permissions: ["ui"], consented: ["ui", "publish", "storage"], source: "bundled")
        let m = PluginManager(bundledDirectory: bundledPluginsDir, installedDirectory: tempDir(), appVersion: "1.1.0", registry: registry, host: host)
        m.reload(config: host.config)
        let req = try #require(popup(try registry.run("com.ntfybar.alert-card.show", host.ctx(msg("b1")), ["snoozeMin": .number(10)])))
        #expect(req.spec.buttons.map(\.id) == ["ack"])
        #expect(req.spec.position == nil, "no choice → the topic's own position")
    }

    // MARK: Repeat & Burst

    @Test func quietForAndBurst() throws {
        let m = load(["com.ntfybar.history-conditions": ["history.read"]])
        #expect(m.package("com.ntfybar.history-conditions")?.state == .active)
        let t: Int64 = 1_700_000_000
        let current = msg("h0", time: t)
        host.messages[host.triggerTopic.id] = [current, msg("h1", time: t - 600), msg("h2", title: "Other", time: t - 60)]
        let quiet = "com.ntfybar.history-conditions.quiet-for", burst = "com.ntfybar.history-conditions.burst"
        #expect(try !registry.evaluate(quiet, host.ctx(current), ["minutes": .number(30)]), "same title 10 min ago")
        #expect(try registry.evaluate(quiet, host.ctx(current), ["minutes": .number(5)]))
        #expect(try registry.evaluate(quiet, host.ctx(current), ["minutes": .number(30), "matchOn": .string("message")]) == false)
        #expect(try registry.evaluate(burst, host.ctx(current), ["count": .number(3), "minutes": .number(15)]))
        #expect(try !registry.evaluate(burst, host.ctx(current), ["count": .number(3), "minutes": .number(15), "matchOn": .string("title")]))
        #expect(try !registry.evaluate(burst, host.ctx(current), ["count": .number(4), "minutes": .number(15)]))
    }

    // MARK: Extract

    @Test func extractCopiesAndOpens() throws {
        let manager = load(["com.ntfybar.extract": ["clipboard.write", "openURL"]])
        defer { withExtendedLifetime(manager) {} }
        let m = msg("e1", title: "Login", body: "Your code: 482193. Review PR #57 (fix & test).")
        _ = try registry.run("com.ntfybar.extract.copy", host.ctx(m), ["pattern": .string(#"code: (\d{6})"#)])
        #expect(host.copied == ["482193"])
        _ = try registry.run("com.ntfybar.extract.copy", host.ctx(m), ["pattern": .string(#"\((.*)\)"#), "group": .number(0)])
        #expect(host.copied.last == "(fix & test)")
        _ = try registry.run("com.ntfybar.extract.open", host.ctx(m), ["pattern": .string(#"\((.*)\)"#),
                                                                        "template": .string("https://example.com/q?s={match}")])
        #expect(host.opened.last?.absoluteString == "https://example.com/q?s=fix%20%26%20test")
        _ = try registry.run("com.ntfybar.extract.copy", host.ctx(m), ["pattern": .string("nothing-here-(\\d+)")])
        #expect(host.copied.count == 2, "no match → nothing copied")
        #expect(throws: (any Error).self) { try registry.run("com.ntfybar.extract.copy", host.ctx(m), ["pattern": .string("([")]) }
        #expect(throws: (any Error).self) {
            try registry.run("com.ntfybar.extract.open", host.ctx(m), ["pattern": .string("PR #(\\d+)"), "template": .string("file:///{match}")])
        }
        #expect(host.opened.count == 1, "file: links never open")
    }

    // MARK: JSON field changed

    @Test func jsonFieldChanged() throws {
        let manager = load(["com.ntfybar.json-fields": ["ui", "history.read"]])
        defer { withExtendedLifetime(manager) {} }
        let now = msg("j2", body: #"{"state":"red"}"#)
        host.messages[host.triggerTopic.id] = [now, msg("j1", body: #"{"state":"green"}"#)]
        let id = "com.ntfybar.json-fields.changed"
        #expect(try registry.evaluate(id, host.ctx(now), ["field": .string("state")]))
        host.messages[host.triggerTopic.id] = [now, msg("j1", body: #"{"state":"red"}"#)]
        #expect(try !registry.evaluate(id, host.ctx(now), ["field": .string("state")]))
        host.messages[host.triggerTopic.id] = [now]
        #expect(try !registry.evaluate(id, host.ctx(now), ["field": .string("state")]), "no previous value → not a change")
    }
}

@Suite("Scheduled publish")
@MainActor
final class ScheduledPublishTests {
    let host = uniqueHost()

    @Test func delayedPublishSkipsTheLoopGuardAndUsesDeliveryTimeForQuietHours() async throws {
        StubProtocol.register(host) { req, _ in req.httpMethod == "POST" ? [.status(200), .line(#"{"id":"later1"}"#), .end] : [.status(200)] }
        let store = ConfigStore(directory: tempDir())
        var c = Config()
        c.servers = [ServerConfig(url: "https://\(host)")]
        let topicId = UUID()
        c.topics = [TopicConfig(id: topicId, serverId: c.servers[0].id, topic: "ntfybar-9f3a1c7b2e", label: "T")]
        try store.saveConfig(c)
        var cal = Calendar.current
        cal.timeZone = .current
        let evening = cal.date(bySettingHour: 19, minute: 50, second: 0, of: Date())!  // +20 min = inside 20:00–09:00
        let e = try Engine(store: store, session: StubProtocol.session(), now: { evening })
        try await e.publish(PublishRequest(topicId: topicId, message: "snoozed", priority: 5, delay: 1200), rateKey: nil)
        let sent = try #require(StubProtocol.bodies(host).first)
        let body = try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(body["priority"] as? Int == 4, "capped for the time it will arrive")
        #expect(body["delay"] as? String == "1200s")
        #expect(e.ownEchoCount == 0, "a scheduled message is meant to come back and run rules")
    }
}

/// Repo-only examples (Time Window, Reply Buttons): run with `NTFYBAR_PLUGINS_REPO=<path>`.
@Suite("Marketplace repo examples", .enabled(if: ProcessInfo.processInfo.environment["NTFYBAR_PLUGINS_REPO"] != nil))
@MainActor
struct RepoExampleTests {
    let host = FakeHost()
    let registry = ProviderRegistry()

    func load(_ id: String, _ perms: [String]) -> PluginManager {
        let repo = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NTFYBAR_PLUGINS_REPO"]!).appendingPathComponent("plugins/\(id)")
        host.config.plugins.localFolders = [repo.path]
        host.config.plugins.grants[id] = PluginGrant(permissions: perms, source: "local:" + repo.path)
        host.grants[id] = Set(perms.compactMap(Permission.init(rawValue:)))
        let m = PluginManager(bundledDirectory: nil, installedDirectory: tempDir(), appVersion: "1.1.0", registry: registry, host: host)
        m.reload(config: host.config)
        return m
    }

    func at(_ weekday: Int, _ h: Int, _ min: Int) -> Message {
        // 2026-10-19 is a Monday (weekday 2 in Calendar terms); add days to reach the wanted weekday.
        var c = DateComponents(year: 2026, month: 10, day: 18 + weekday - 1, hour: h, minute: min)
        c.timeZone = .current
        let t = Int64(Calendar.current.date(from: c)!.timeIntervalSince1970)
        return makeMessage(topicId: host.triggerTopic.id, id: "t\(weekday)\(h)\(min)", time: t)
    }

    @Test func timeWindow() throws {
        // Local folders are unverified, so the reserved com.ntfybar.* id is refused there: copy it under a neutral id.
        let src = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NTFYBAR_PLUGINS_REPO"]!).appendingPathComponent("plugins/com.ntfybar.time-window")
        let dir = tempDir().appendingPathComponent("com.example.time-window")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var manifest = try String(contentsOf: src.appendingPathComponent("plugin.json"), encoding: .utf8)
        manifest = manifest.replacingOccurrences(of: "com.ntfybar.time-window", with: "com.example.time-window").replacingOccurrences(of: "NtfyBar", with: "Example")
        try manifest.write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: src.appendingPathComponent("main.js"), to: dir.appendingPathComponent("main.js"))
        host.config.plugins.localFolders = [dir.path]
        host.config.plugins.grants["com.example.time-window"] = PluginGrant(permissions: [], source: "local:" + dir.path)
        let m = PluginManager(bundledDirectory: nil, installedDirectory: tempDir(), appVersion: "1.1.0", registry: registry, host: host)
        m.reload(config: host.config)
        defer { withExtendedLifetime(m) {} }
        let id = "com.example.time-window.within"
        let weekdays: Params = ["from": .string("09:00"), "to": .string("18:00"), "days": .string("mon-fri")]
        #expect(try registry.evaluate(id, host.ctx(at(2, 10, 0)), weekdays), "Monday 10:00")
        #expect(try !registry.evaluate(id, host.ctx(at(2, 18, 0)), weekdays), "18:00 is outside")
        #expect(try !registry.evaluate(id, host.ctx(at(7, 10, 0)), weekdays), "Saturday")
        let night: Params = ["from": .string("22:00"), "to": .string("06:00"), "days": .string("mon-fri")]
        #expect(try registry.evaluate(id, host.ctx(at(6, 23, 30)), night), "Friday 23:30")
        #expect(try registry.evaluate(id, host.ctx(at(7, 2, 0)), night), "Saturday 02:00 belongs to Friday night")
        #expect(try !registry.evaluate(id, host.ctx(at(2, 2, 0)), night), "Monday 02:00 belongs to Sunday night")
    }

    @Test func replyButtons() throws {
        let src = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NTFYBAR_PLUGINS_REPO"]!).appendingPathComponent("plugins/com.ntfybar.reply-buttons")
        let dir = tempDir().appendingPathComponent("com.example.reply-buttons")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var manifest = try String(contentsOf: src.appendingPathComponent("plugin.json"), encoding: .utf8)
        manifest = manifest.replacingOccurrences(of: "com.ntfybar.reply-buttons", with: "com.example.reply-buttons").replacingOccurrences(of: "NtfyBar", with: "Example")
        try manifest.write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: src.appendingPathComponent("main.js"), to: dir.appendingPathComponent("main.js"))
        host.config.plugins.localFolders = [dir.path]
        host.config.plugins.grants["com.example.reply-buttons"] = PluginGrant(permissions: ["ui", "publish"], source: "local:" + dir.path)
        host.grants["com.example.reply-buttons"] = [.ui, .publish]
        let m = PluginManager(bundledDirectory: nil, installedDirectory: tempDir(), appVersion: "1.1.0", registry: registry, host: host)
        m.reload(config: host.config)
        let target = host.otherTopic.id.uuidString
        let out = try registry.run("com.example.reply-buttons.show", host.ctx(), ["topic": .string(target),
            "button1": .string("Close garage=garage close"), "button2": .string("Ignore=garage ignore"), "button3": .string("broken")])
        guard case let .pluginPopup(req)? = out.effects.first else { Issue.record("no popup"); return }
        #expect(req.spec.buttons.map(\.label) == ["Close garage", "Ignore"])
        #expect(try m.runtime("com.example.reply-buttons")!.popupAction(ctx: host.ctx(), buttonId: "b1", state: req.spec.state) == .close)
        #expect(host.published.last?.1.topicId == host.otherTopic.id && host.published.last?.1.message == "garage close")
    }
}
