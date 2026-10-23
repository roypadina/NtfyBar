import Foundation
import Testing
@testable import NtfyBarCore

/// In-memory host: two topics on two servers, grants per plugin, recorded side effects.
@MainActor
final class FakeHost: PluginHost {
    var config = Config()
    var grants: [String: Set<Permission>] = [:]
    var messages: [UUID: [Message]] = [:]
    var published: [(String, PublishRequest)] = []
    var copied: [String] = []
    var opened: [URL] = []
    let pluginDataDirectory = tempDir()

    let triggerTopic: TopicConfig
    let otherTopic: TopicConfig

    init() {
        let selfHosted = ServerConfig(url: "https://ntfy.home.example:8443")
        config.servers.append(selfHosted)
        triggerTopic = TopicConfig(serverId: config.servers[0].id, topic: "ntfybar-trigger9f3a1c", label: "Builds")
        otherTopic = TopicConfig(serverId: selfHosted.id, topic: "ntfybar-other4b2d8e", label: "Home")
        config.topics = [triggerTopic, otherTopic]
    }

    func isGranted(_ pluginId: String, _ p: Permission) -> Bool { grants[pluginId]?.contains(p) ?? false }
    func history(topicId: UUID, before: Int64?, after: Int64?, limit: Int) -> [Message] { Array((messages[topicId] ?? []).prefix(limit)) }
    func publish(pluginId: String, _ request: PublishRequest) { published.append((pluginId, request)) }
    func copy(_ text: String) { copied.append(text) }
    func open(_ url: URL) { opened.append(url) }

    func ctx(_ m: Message? = nil) -> ProviderContext {
        ProviderContext(message: m ?? makeMessage(topicId: triggerTopic.id, id: "trig", title: "Hello", body: "World"),
                        topic: triggerTopic, config: config)
    }
}

@Suite("Plugin capability enforcement")
@MainActor
struct CapabilityTests {
    let host = FakeHost()
    let id = "com.example.probe"

    /// One probe per permission: returns true when the call worked.
    nonisolated static let probes: [Permission: (name: String, js: String)] = [
        .historyRead: ("history", "return Array.isArray(ntfy.history({limit: 5}));"),
        .topicsRead: ("topics", "return ntfy.topics().length === 2;"),
        .publish: ("publish", "return ntfy.publish({topicId: ctx.topic.id, message: 'x'}) === true;"),
        .clipboardWrite: ("copy", "return ntfy.copy('hi') === true;"),
        .openURL: ("openURL", "return ntfy.openURL('https://example.com/x') === true;"),
        .storage: ("storage", "return ntfy.storage.set('k', 1) === true && ntfy.storage.get('k') === 1;")
    ]

    func runtime(_ granted: Set<Permission>, extra: String = "") throws -> PluginRuntime {
        var script = extra
        for (_, probe) in Self.probes {
            script += "function probe_\(probe.name)(ctx) { \(probe.js) }\n"
            script += "function has_\(probe.name)(ctx) { return typeof ntfy.\(probe.name) !== 'undefined'; }\n"
        }
        return try PluginRuntime(pluginId: id, script: script, granted: granted, host: host)
    }

    @Test(arguments: Array(probes.keys))
    func absentGrantedRevoked(_ p: Permission) throws {
        let name = Self.probes[p]!.name
        // Absent: method not installed, calling it fails.
        let none = try runtime([])
        #expect(try none.condition("has_\(name)", ctx: host.ctx(), params: [:]) == false)
        #expect(throws: PluginError.self) { try none.condition("probe_\(name)", ctx: host.ctx(), params: [:]) }

        // Granted: works.
        host.grants[id] = [p]
        let granted = try runtime([p])
        #expect(try granted.condition("has_\(name)", ctx: host.ctx(), params: [:]))
        #expect(try granted.condition("probe_\(name)", ctx: host.ctx(), params: [:]))

        // Revoked without a rebuild: the per-call re-check refuses.
        host.grants[id] = []
        #expect(throws: PluginError.self) { try granted.condition("probe_\(name)", ctx: host.ctx(), params: [:]) }

        // Revoked and rebuilt: gone again.
        let rebuilt = try runtime([])
        #expect(try rebuilt.condition("has_\(name)", ctx: host.ctx(), params: [:]) == false)
    }

    @Test func sideEffectsReachTheHost() throws {
        host.grants[id] = Set(Permission.allCases)
        let r = try runtime(Set(Permission.allCases))
        for (_, probe) in Self.probes { _ = try r.condition("probe_\(probe.name)", ctx: host.ctx(), params: [:]) }
        #expect(host.published.count == 1 && host.published[0].0 == id && host.published[0].1.topicId == host.triggerTopic.id)
        #expect(host.copied == ["hi"])
        #expect(host.opened == [URL(string: "https://example.com/x")!])
    }

    @Test func uiPermissionGatesPopups() throws {
        let script = "function act(ctx) { return {popup: {title: 'Hi', buttons: [{id: 'a', label: 'A'}]}}; }"
        host.grants[id] = []
        let without = try PluginRuntime(pluginId: id, script: script, granted: [], host: host)
        #expect(throws: PluginError.permissionDenied("ui")) { try without.action("act", ctx: host.ctx(), params: [:]) }
        host.grants[id] = [.ui]
        let with = try PluginRuntime(pluginId: id, script: script, granted: [.ui], host: host)
        #expect(try with.action("act", ctx: host.ctx(), params: [:])?.title == "Hi")
    }

    @Test func historyIsTriggerTopicOnlyWithoutTopicsRead() throws {
        host.messages[host.triggerTopic.id] = (0..<300).map { makeMessage(topicId: host.triggerTopic.id, id: "t\($0)") }
        host.messages[host.otherTopic.id] = [makeMessage(topicId: host.otherTopic.id, id: "o1")]
        let script = """
            function mine(ctx) { return ntfy.history({}).length === 50 && ntfy.history({limit: 500}).length === 200; }
            function other(ctx, p) { return ntfy.history({topicId: p.t}).length === 1; }
            """
        host.grants[id] = [.historyRead]
        let r = try PluginRuntime(pluginId: id, script: script, granted: [.historyRead], host: host)
        #expect(try r.condition("mine", ctx: host.ctx(), params: [:]))
        #expect(throws: PluginError.self) {
            try r.condition("other", ctx: host.ctx(), params: ["t": .string(host.otherTopic.id.uuidString)])
        }
        host.grants[id] = [.historyRead, .topicsRead]
        let both = try PluginRuntime(pluginId: id, script: script, granted: [.historyRead, .topicsRead], host: host)
        #expect(try both.condition("other", ctx: host.ctx(), params: ["t": .string(host.otherTopic.id.uuidString)]))
    }

    @Test func publishOnlyToConfiguredTopicsAndOpenOnlyHttp() throws {
        let script = """
            function badTopic(ctx) { return ntfy.publish({topicId: '00000000-0000-0000-0000-000000000000', message: 'x'}); }
            function noMessage(ctx) { return ntfy.publish({topicId: ctx.topic.id}); }
            function fileURL(ctx) { return ntfy.openURL('file:///etc/passwd'); }
            function shortcut(ctx) { return ntfy.openURL('shortcuts://run-shortcut?name=x'); }
            """
        host.grants[id] = [.publish, .openURL]
        let r = try PluginRuntime(pluginId: id, script: script, granted: [.publish, .openURL], host: host)
        for fn in ["badTopic", "noMessage", "fileURL", "shortcut"] {
            #expect(throws: PluginError.self) { try r.condition(fn, ctx: host.ctx(), params: [:]) }
        }
        #expect(host.published.isEmpty && host.opened.isEmpty)
    }

    @Test func redactionCoversEveryStringPluginsSee() throws {
        let t = host.triggerTopic.topic, o = host.otherTopic.topic
        let n = NtfyMessage(id: "r1", time: 1, topic: t, title: "Re: \(t)", message: "see https://ntfy.sh/\(t) and \(o)",
                            click: "https://ntfy.sh/\(t)?x=1",
                            actions: [NtfyAction(action: "http", label: "Ack", url: "https://ntfy.home.example:8443/\(o)",
                                                 headers: ["X-Topic": t], body: "ack \(t)")],
                            attachment: NtfyAttachment(name: "a.png", url: "https://ntfy.sh/file/\(t).png"), icon: "https://ntfy.home.example:8443/i.png")
        let m = Message(topicId: host.triggerTopic.id, ntfy: n, receivedAt: Date(), isCatchUp: false, raw: "{\"topic\":\"\(t)\"}")
        host.messages[host.otherTopic.id] = [makeMessage(topicId: host.otherTopic.id, id: "o1", title: o, body: "on \(o)")]
        let script = """
            function dump(ctx, p) {
              var all = JSON.stringify(ctx) + JSON.stringify(ntfy.history({})) + JSON.stringify(ntfy.history({topicId: p.t})) + JSON.stringify(ntfy.topics());
              var blocks = [];
              for (var i = 0; i < all.length; i += 4000) blocks.push({text: all.slice(i, i + 4000)});
              return {popup: {title: 'dump', blocks: blocks}};
            }
            """
        let all: Set<Permission> = [.historyRead, .topicsRead, .ui]
        host.grants[id] = all
        host.messages[host.triggerTopic.id] = [m]
        let r = try PluginRuntime(pluginId: id, script: script, granted: all, host: host)
        let spec = try #require(try r.action("dump", ctx: host.ctx(m), params: ["t": .string(host.otherTopic.id.uuidString)]))
        let text = spec.blocks.compactMap { if case let .text(s, _) = $0 { s } else { nil } }.joined()
        #expect(text.contains("\"id\":\"r1\""), "the message itself is there")
        for secret in [t, o, "ntfy.sh", "ntfy.home.example"] {
            #expect(!text.localizedCaseInsensitiveContains(secret), "\(secret) leaked")
        }
        #expect(!text.contains("\"topic\":\"ntfybar"), "no raw topic field")
    }

    @Test func watchdogStopsLoopsAndTheContextSurvives() throws {
        let script = """
            function spin(ctx) { while (true) {} }
            function fine(ctx) { return true; }
            """
        let r = try PluginRuntime(pluginId: id, script: script, granted: [], host: host, timeLimit: 0.3)
        let start = Date()
        #expect(throws: PluginError.timedOut) { try r.condition("spin", ctx: host.ctx(), params: [:]) }
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(try r.condition("fine", ctx: host.ctx(), params: [:]), "same context still works")
        #expect(throws: PluginError.timedOut) { try r.condition("spin", ctx: host.ctx(), params: [:]) }
        #expect(throws: PluginError.timedOut) { try r.condition("spin", ctx: host.ctx(), params: [:]) }
        #expect(r.isDisabled)
        #expect(throws: PluginError.disabled) { try r.condition("fine", ctx: host.ctx(), params: [:]) }
    }

    @Test func wrongReturnTypesAndExceptions() throws {
        let script = """
            function str(ctx) { return 'yes'; }
            function num(ctx) { return 42; }
            function boom(ctx) { throw new Error('nope'); }
            function noPopupKey(ctx) { return {other: 1}; }
            """
        let r = try PluginRuntime(pluginId: id, script: script, granted: [.ui], host: host)
        host.grants[id] = [.ui]
        #expect(throws: PluginError.self) { try r.condition("str", ctx: host.ctx(), params: [:]) }
        #expect(throws: PluginError.self) { try r.action("num", ctx: host.ctx(), params: [:]) }
        #expect(throws: PluginError.threw("nope")) { try r.condition("boom", ctx: host.ctx(), params: [:]) }
        #expect(throws: PluginError.self) { try r.action("noPopupKey", ctx: host.ctx(), params: [:]) }
        #expect(throws: PluginError.missingFunction("absent")) { try r.condition("absent", ctx: host.ctx(), params: [:]) }
        #expect(throws: PluginError.self) { try PluginRuntime(pluginId: id, script: "function (", granted: [], host: host) }
    }

    @Test func nothingButNtfyAndECMAScriptIsInjected() throws {
        let script = """
            function globals(ctx) {
              return typeof fetch === 'undefined' && typeof XMLHttpRequest === 'undefined' && typeof require === 'undefined'
                && typeof setTimeout === 'undefined' && typeof process === 'undefined' && typeof ntfy === 'object';
            }
            """
        #expect(try PluginRuntime(pluginId: id, script: script, granted: [], host: host).condition("globals", ctx: host.ctx(), params: [:]))
    }

    @Test func storageIsScopedAndCapped() throws {
        host.grants["com.example.a"] = [.storage]
        host.grants["com.example.b"] = [.storage]
        let script = """
            function put(ctx, p) { return ntfy.storage.set(p.k, p.v); }
            function get(ctx, p) { return ntfy.storage.get(p.k) === p.v; }
            function missing(ctx, p) { return typeof ntfy.storage.get(p.k) === 'undefined'; }
            function big(ctx) { return ntfy.storage.set('big', new Array(1100000).join('x')); }
            """
        let a = try PluginRuntime(pluginId: "com.example.a", script: script, granted: [.storage], host: host)
        let b = try PluginRuntime(pluginId: "com.example.b", script: script, granted: [.storage], host: host)
        #expect(try a.condition("put", ctx: host.ctx(), params: ["k": .string("x"), "v": .string("1")]))
        #expect(try a.condition("get", ctx: host.ctx(), params: ["k": .string("x"), "v": .string("1")]))
        #expect(try b.condition("missing", ctx: host.ctx(), params: ["k": .string("x")]), "b can't see a's data")
        #expect(throws: PluginError.self) { try a.condition("big", ctx: host.ctx(), params: [:]) }
        let file = host.pluginDataDirectory.appendingPathComponent("com.example.a.json")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
    }
}

@Suite("Popup spec")
struct PopupSpecTests {
    func parse(_ json: String) throws -> PopupSpec { try PopupSpec.parse(JSONValue.parse(json)!) }

    @Test func validSpecWithUnknownKeysIgnored() throws {
        let s = try parse("""
            {"title":"Deploy","icon":"checkmark.seal","accent":"success","timeoutSec":30,"future":"x",
             "blocks":[{"text":"**done**"},{"kv":[["a","1"],["b","2"]]},{"progress":0.5,"label":"half"},{"badge":"OK"},{"unknownBlock":1}],
             "buttons":[{"id":"ok","label":"OK","style":"prominent","extra":true}],"state":{"n":1}}
            """)
        #expect(s.blocks.count == 4 && s.buttons.count == 1 && s.state == .object(["n": .number(1)]) && s.accent == .success)
        let content = s.content(key: "k", label: "Builds", pluginName: "Probe", topicId: nil, messageId: nil)
        #expect(content.header == "Builds · Probe", "plugin popups say which plugin made them")
        #expect(content.buttons.map(\.id) == ["ok", "dismiss"])
    }

    @Test(arguments: [
        #"{"blocks":[]}"#,
        #"{"title":""}"#,
        #"{"title":"x","accent":"purple"}"#,
        #"{"title":"x","timeoutSec":9999}"#,
        #"{"title":"x","blocks":[{"progress":1.5}]}"#,
        #"{"title":"x","blocks":[{"kv":[["only-key"]]}]}"#,
        #"{"title":"x","buttons":[{"id":"a","label":"A"},{"id":"b","label":"B"},{"id":"c","label":"C"},{"id":"d","label":"D"}]}"#,
        #"{"title":"x","buttons":[{"id":"a","label":"A"},{"id":"a","label":"B"}]}"#,
        #"{"title":"x","buttons":[{"id":"bad id","label":"A"}]}"#,
        #"{"title":"x","buttons":[{"id":"a","label":"A","style":"loud"}]}"#,
        #"{"title":"x","icon":"../../etc"}"#,
        #""just a string""#
    ])
    func rejects(_ json: String) {
        #expect(throws: PopupSpec.Invalid.self) { try parse(json) }
    }

    @Test func sizeCaps() {
        let longText = String(repeating: "a", count: 5000)
        #expect(throws: PopupSpec.Invalid.self) { try parse(#"{"title":"x","blocks":[{"text":"\#(longText)"}]}"#) }
        let blocks = Array(repeating: #"{"badge":"b"}"#, count: 21).joined(separator: ",")
        #expect(throws: PopupSpec.Invalid.self) { try parse(#"{"title":"x","blocks":[\#(blocks)]}"#) }
        let bigState = String(repeating: "s", count: 70_000)
        #expect(throws: PopupSpec.Invalid.self) { try parse(#"{"title":"x","state":"\#(bigState)"}"#) }
    }
}

@Suite("Plugin manifest")
struct ManifestTests {
    static let valid = """
        {"id":"com.example.demo","name":"Demo","version":"1.0.0","description":"A demo plugin.","apiVersion":1,"minAppVersion":"1.0.0",
         "entry":"main.js","files":["plugin.json","main.js"],"permissions":["ui","publish"],
         "permissionReasons":{"ui":"Shows a popup.","publish":"Sends a reply."},
         "providers":[{"id":"com.example.demo.act","kind":"action","name":"Act","description":"Does it.","function":"act",
                       "params":[{"key":"x","label":"X","kind":"text"}]}],
         "popup":{"engine":"declarative"}}
        """

    func manifest(_ patch: (inout [String: Any]) -> Void = { _ in }) throws -> PluginManifest {
        var obj = try JSONSerialization.jsonObject(with: Data(Self.valid.utf8)) as! [String: Any]
        patch(&obj)
        return try JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: obj))
    }

    let sizes = ["plugin.json": 500, "main.js": 300]

    @Test func validPasses() throws {
        let m = try manifest()
        #expect(m.packageErrors(folderName: "com.example.demo", fileSizes: sizes, appVersion: "1.0.0").isEmpty)
        #expect(m.providerErrors(m.providers[0]).isEmpty)
    }

    @Test func packageRejections() throws {
        func errors(_ patch: (inout [String: Any]) -> Void, folder: String? = "com.example.demo", files: [String: Int]? = nil) throws -> [String] {
            try manifest(patch).packageErrors(folderName: folder, fileSizes: files ?? sizes, appVersion: "1.0.0")
        }
        #expect(try !errors { $0["permissionReasons"] = ["ui": "Shows a popup."] }.isEmpty, "missing reason")
        #expect(try !errors { $0["permissions"] = ["ui", "network"]; $0["permissionReasons"] = ["ui": "a", "network": "b"] }.isEmpty, "unknown permission")
        #expect(try errors { $0["popup"] = ["engine": "html"] }.contains { $0.contains("html") })
        #expect(try !errors({ _ in }, files: ["plugin.json": 1]).isEmpty, "missing file")
        #expect(try !errors { $0["description"] = String(repeating: "d", count: 121) }.isEmpty)
        #expect(try !errors { $0["id"] = "Demo" }.isEmpty, "bad id")
        #expect(try !errors({ _ in }, folder: "other-name").isEmpty, "folder ≠ id")
        #expect(try !errors { $0["minAppVersion"] = "9.0" }.isEmpty)
        #expect(try !errors { $0["apiVersion"] = 2 }.isEmpty)
        #expect(try !errors { $0["files"] = ["plugin.json", "main.js", "../evil"] }.isEmpty)
        #expect(try !errors({ _ in }, files: ["plugin.json": 1, "main.js": 3 * 1024 * 1024]).isEmpty, "file too large")
    }

    @Test func providerRejectionsOnlySkipTheProvider() throws {
        let m = try manifest()
        var p = m.providers[0]
        p.id = "builtin.notify"
        #expect(!m.providerErrors(p).isEmpty, "can't impersonate built-ins")
        p = m.providers[0]
        p.params = [ParamSpec("x", "X", .choice)]
        #expect(!m.providerErrors(p).isEmpty, "choice is built-in only")
        p = m.providers[0]
        p.function = "a b"
        #expect(!m.providerErrors(p).isEmpty)
    }
}
