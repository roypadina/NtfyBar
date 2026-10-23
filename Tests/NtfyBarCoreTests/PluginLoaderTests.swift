import Foundation
import Testing
@testable import NtfyBarCore

/// Repo `Resources/BundledPlugins`, found relative to this test file.
let bundledPluginsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/BundledPlugins")

func writePackage(_ dir: URL, id: String, permissions: [String] = [], script: String = "function act(ctx) { return undefined; }",
                  providers: String? = nil, folderName: String? = nil) throws -> URL {
    let folder = dir.appendingPathComponent(folderName ?? id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let reasons = Dictionary(uniqueKeysWithValues: permissions.map { ($0, "Needed for the test.") })
    let manifest: [String: Any] = [
        "id": id, "name": "Test", "version": "1.0.0", "description": "Test plugin.", "apiVersion": 1, "entry": "main.js",
        "files": ["plugin.json", "main.js"], "permissions": permissions, "permissionReasons": reasons,
        "providers": try JSONSerialization.jsonObject(with: Data((providers ?? """
            [{"id":"\(id).act","kind":"action","name":"Act","description":"Acts.","function":"act"},
             {"id":"\(id).broken","kind":"action","name":"Broken","description":"Missing function.","function":"nothere"}]
            """).utf8))
    ]
    try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("plugin.json"))
    try Data(script.utf8).write(to: folder.appendingPathComponent("main.js"))
    return folder
}

@Suite("Plugin loader")
@MainActor
struct PluginLoaderTests {
    let host = FakeHost()
    let registry = ProviderRegistry()
    let bundled = tempDir()
    let installed = tempDir()

    func manager() -> PluginManager {
        PluginManager(bundledDirectory: bundled, installedDirectory: installed, appVersion: "1.0.0", registry: registry, host: host)
    }

    @Test func badPackageSkippedGoodOneWaitsForConsent() throws {
        _ = try writePackage(bundled, id: "com.example.good", permissions: ["ui"])
        let bad = bundled.appendingPathComponent("com.example.bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: bad.appendingPathComponent("plugin.json"))
        let m = manager()
        m.reload(config: host.config)
        #expect(m.package("com.example.good")?.state == .needsConsent)
        #expect(m.packages.contains { $0.state == .invalid })
        #expect(registry.catalog(.action).allSatisfy { $0.packageId == nil }, "nothing registered before consent")
    }

    @Test func consentActivatesValidProvidersOnly() throws {
        _ = try writePackage(bundled, id: "com.example.good", permissions: ["ui"])
        host.config.plugins.grants["com.example.good"] = PluginGrant(permissions: ["ui"], source: "bundled")
        let m = manager()
        m.reload(config: host.config)
        let pkg = try #require(m.package("com.example.good"))
        #expect(pkg.state == .active)
        #expect(registry.descriptors["com.example.good.act"] != nil)
        #expect(registry.descriptors["com.example.good.broken"] == nil, "a bad provider skips only itself")
        #expect(pkg.errors.contains { $0.contains("nothere") })
        // Reload without restart: removing the grant unregisters it.
        host.config.plugins.grants = [:]
        m.reload(config: host.config)
        #expect(registry.descriptors["com.example.good.act"] == nil)
    }

    @Test func grantsAreBoundToTheirSource() throws {
        let local = tempDir()
        _ = try writePackage(local, id: "com.ntfybar.ack-button", permissions: ["publish"])
        host.config.plugins.localFolders = [local.path]
        host.config.plugins.grants["com.ntfybar.ack-button"] = PluginGrant(permissions: ["publish"], source: "bundled")
        let m = manager()
        m.reload(config: host.config)
        #expect(m.package("com.ntfybar.ack-button")?.state == .needsConsent, "a local copy doesn't inherit the bundled grant")
        #expect(m.package("com.ntfybar.ack-button")?.verified == false)
    }

    @Test func duplicateIdIsRefused() throws {
        _ = try writePackage(bundled, id: "com.example.dup")
        let local = tempDir()
        _ = try writePackage(local, id: "com.example.dup")
        host.config.plugins.localFolders = [local.path]
        let m = manager()
        m.reload(config: host.config)
        #expect(m.packages.filter { $0.id == "com.example.dup" }.map(\.state) == [.needsConsent, .invalid])
    }

    @Test func newPermissionInAnUpdateNeedsConsentAgain() throws {
        _ = try writePackage(bundled, id: "com.example.grow", permissions: ["ui", "publish"])
        host.config.plugins.grants["com.example.grow"] = PluginGrant(permissions: ["ui"], source: "bundled")
        let m = manager()
        m.reload(config: host.config)
        #expect(m.package("com.example.grow")?.state == .needsConsent)
    }

    @Test func switchedOffPermissionIsAbsentInJS() throws {
        let script = "function act(ctx) { return undefined; } function hasPublish(ctx) { return typeof ntfy.publish !== 'undefined'; }"
        _ = try writePackage(bundled, id: "com.example.off", permissions: ["publish"], script: script, providers: """
            [{"id":"com.example.off.has","kind":"condition","name":"Has","description":"Has publish.","function":"hasPublish"}]
            """)
        host.config.plugins.grants["com.example.off"] = PluginGrant(permissions: [], consented: ["publish"], source: "bundled")
        let m = manager()
        m.reload(config: host.config)
        #expect(m.package("com.example.off")?.state == .active)
        let ctx = host.ctx()
        #expect(try registry.evaluate("com.example.off.has", ctx, [:]) == false)
    }

    @Test func disabledPackagesStayOff() throws {
        _ = try writePackage(bundled, id: "com.example.off2")
        host.config.plugins.grants["com.example.off2"] = PluginGrant(permissions: [], source: "bundled")
        host.config.plugins.disabledIds = ["com.example.off2"]
        let m = manager()
        m.reload(config: host.config)
        #expect(m.package("com.example.off2")?.state == .disabled)
    }
}

@Suite("Bundled examples")
@MainActor
struct BundledExampleTests {
    let host = FakeHost()
    let registry = ProviderRegistry()

    func load(_ grants: [String: [String]]) -> PluginManager {
        for (id, perms) in grants { host.config.plugins.grants[id] = PluginGrant(permissions: perms, source: "bundled") }
        let m = PluginManager(bundledDirectory: bundledPluginsDir, installedDirectory: tempDir(), appVersion: "1.0.0", registry: registry, host: host)
        m.reload(config: host.config)
        return m
    }

    @Test func bothValidateAndWaitForConsent() {
        let m = load([:])
        #expect(m.packages.map(\.id).sorted() == ["com.ntfybar.ack-button", "com.ntfybar.json-fields"])
        #expect(m.packages.allSatisfy { $0.state == .needsConsent && $0.errors.isEmpty && $0.verified })
    }

    @Test func ackButtonPopupThenReply() throws {
        let perms = ["ui", "publish", "storage"]
        let m = load(["com.ntfybar.ack-button": perms])
        host.grants["com.ntfybar.ack-button"] = Set(perms.compactMap(Permission.init(rawValue:)))
        let msg = makeMessage(topicId: host.triggerTopic.id, id: "alert1", title: "Disk full", body: "94%", priority: 5)
        let out = try registry.run("com.ntfybar.ack-button.show", host.ctx(msg), ["reply": .string("ACK {title}")])
        guard case let .pluginPopup(req)? = out.effects.first else { Issue.record("no popup"); return }
        #expect(req.spec.buttons.map(\.id) == ["ack"] && req.spec.accent == .critical)
        let result = try m.runtime("com.ntfybar.ack-button")!.popupAction(ctx: host.ctx(msg), buttonId: "ack", state: req.spec.state)
        #expect(result == .close)
        #expect(host.published.count == 1)
        let reply = host.published[0].1
        #expect(reply.topicId == host.triggerTopic.id && reply.message == "ACK Disk full" && reply.priority == 2)
        #expect(reply.tags.contains("ntfybar-ack"))
        // Its own reply never gets an ACK popup; an acknowledged alert shows a badge, no button.
        let echo = makeMessage(topicId: host.triggerTopic.id, id: "echo", title: "ACK", tags: ["white_check_mark", "ntfybar-ack"])
        #expect(try registry.run("com.ntfybar.ack-button.show", host.ctx(echo), [:]).effects.isEmpty)
        let again = try registry.run("com.ntfybar.ack-button.show", host.ctx(msg), [:])
        if case let .pluginPopup(r)? = again.effects.first { #expect(r.spec.buttons.isEmpty) } else { Issue.record("no popup") }
    }

    @Test func jsonFieldsConditionAndTable() throws {
        let perms = ["ui", "history.read"]
        let manager = load(["com.ntfybar.json-fields": perms])
        defer { withExtendedLifetime(manager) {} }
        host.grants["com.ntfybar.json-fields"] = Set(perms.compactMap(Permission.init(rawValue:)))
        let current = makeMessage(topicId: host.triggerTopic.id, id: "j2", title: "Sensor", body: #"{"temp":23,"status":{"code":"ok"}}"#)
        let older = makeMessage(topicId: host.triggerTopic.id, id: "j1", body: #"{"temp":21}"#)
        host.messages[host.triggerTopic.id] = [current, older]
        #expect(try registry.evaluate("com.ntfybar.json-fields.equals", host.ctx(current), ["field": .string("status.code"), "value": .string("ok")]))
        #expect(try !registry.evaluate("com.ntfybar.json-fields.equals", host.ctx(current), ["field": .string("status.code"), "value": .string("bad")]))
        #expect(try !registry.evaluate("com.ntfybar.json-fields.equals", host.ctx(makeMessage(topicId: host.triggerTopic.id, body: "plain")),
                                       ["field": .string("a"), "value": .string("b")]))
        let out = try registry.run("com.ntfybar.json-fields.table", host.ctx(current), ["field": .string("temp")])
        guard case let .pluginPopup(req)? = out.effects.first else { Issue.record("no popup"); return }
        #expect(req.spec.blocks.last == .keyValue([PopupContent.KV("temp now", "23"), PopupContent.KV("temp before", "21")]))
    }
}

@Suite("Marketplace")
@MainActor
final class MarketplaceTests {
    let host = uniqueHost()
    var files: [String: Data] = [:]
    var entry: MarketplaceEntry!

    init() throws {
        let src = try writePackage(tempDir(), id: "com.example.market", permissions: ["ui"])
        files = ["plugin.json": try Data(contentsOf: src.appendingPathComponent("plugin.json")),
                 "main.js": try Data(contentsOf: src.appendingPathComponent("main.js"))]
        entry = MarketplaceEntry(id: "com.example.market", name: "Market", description: "d", version: "1.0.0", permissions: ["ui"],
                                 source: .init(type: "github", repo: "someone/plugins", ref: "main", path: "plugins/com.example.market"),
                                 files: files.mapValues(Marketplace.sha256Hex))
    }

    func serve(_ files: [String: Data]) {
        StubProtocol.register(host) { req, _ in
            guard let name = req.url?.lastPathComponent, let data = files[name] else { return [.status(404), .end] }
            return [.status(200), .data(data), .end]
        }
    }

    func prepare(_ e: MarketplaceEntry) async throws -> PreparedInstall {
        try await Marketplace.prepare(e, marketplaceURL: "https://example.com/m.json", session: StubProtocol.session(),
                                      appVersion: "1.0.0", rawBase: "https://\(host)")
    }

    @Test func verifiedInstallLandsAtomically() async throws {
        serve(files)
        let p = try await prepare(entry)
        let dir = tempDir()
        let dest = try Marketplace.commit(p, into: dir)
        #expect(dest.lastPathComponent == "com.example.market")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted() == ["main.js", "plugin.json"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["com.example.market"], "no temp folder left")
        let path = StubProtocol.requests(host).first?.url?.path ?? ""
        #expect(path.hasPrefix("/someone/plugins/main/plugins/com.example.market/"))
    }

    @Test func tamperedFileIsRefusedAndTheOldVersionStays() async throws {
        let dir = tempDir()
        serve(files)
        try Marketplace.commit(try await prepare(entry), into: dir)
        var tampered = files
        tampered["main.js"] = Data("function act(ctx) { ntfy.copy('pwned'); }".utf8)
        serve(tampered)
        await #expect(throws: MarketplaceError.checksumMismatch("main.js")) { _ = try await self.prepare(self.entry) }
        #expect(try Data(contentsOf: dir.appendingPathComponent("com.example.market/main.js")) == files["main.js"])
    }

    @Test func entryAndManifestMustAgree() async throws {
        serve(files)
        var wrongId = entry!
        wrongId.id = "com.example.other"
        await #expect(throws: MarketplaceError.self) { _ = try await self.prepare(wrongId) }
        var wrongPerms = entry!
        wrongPerms.permissions = []
        await #expect(throws: MarketplaceError.invalidPackage(["manifest permissions differ from the marketplace entry"])) {
            _ = try await self.prepare(wrongPerms)
        }
    }

    @Test func hostileEntriesNeverDownload() async throws {
        serve(files)
        var e = entry!
        e.files["../evil"] = String(repeating: "a", count: 64)
        await #expect(throws: MarketplaceError.self) { _ = try await self.prepare(e) }
        e = entry!
        e.source.path = "../../etc"
        await #expect(throws: MarketplaceError.self) { _ = try await self.prepare(e) }
        e = entry!
        e.source.repo = "a/b/c?x"
        await #expect(throws: MarketplaceError.self) { _ = try await self.prepare(e) }
        e = entry!
        e.source.type = "url"
        await #expect(throws: MarketplaceError.self) { _ = try await self.prepare(e) }
        #expect(StubProtocol.requests(host).isEmpty)
    }

    @Test func oversizedFileIsRefused() async throws {
        var big = files
        big["main.js"] = Data(repeating: 0x20, count: PluginManifest.maxFileBytes + 1)
        serve(big)
        var e = entry!
        e.files["main.js"] = Marketplace.sha256Hex(big["main.js"]!)
        await #expect(throws: MarketplaceError.self) { _ = try await self.prepare(e) }
    }

    @Test func indexMustBeHttps() async {
        await #expect(throws: MarketplaceError.self) {
            _ = try await Marketplace.fetchIndex(URL(string: "http://example.com/m.json")!, session: StubProtocol.session())
        }
    }
}
