import Foundation
import Testing
@testable import NtfyBarCore

/// The 1.4 migration runs once, at the first Engine start on 1.3 files, and backs them up.
@Suite("Engine migration")
@MainActor
struct EngineMigrationTests {
    /// 1.3 files as 1.3 wrote them: no schemaVersion, topic toggles instead of bands.
    func writeLegacy(_ store: ConfigStore, rules: [Rule]) throws -> UUID {
        let server = Config().servers[0]
        let topicId = UUID()
        let config = """
        {"servers":[{"id":"\(server.id)","url":"https://ntfy.sh","auth":{"type":"none"}}],
         "topics":[{"id":"\(topicId)","serverId":"\(server.id)","topic":"ntfybar-9f3a1c7b2e","label":"NAS","notify":true,
                    "popup":{"enabled":false,"timeoutSec":20,"stickyForUrgent":true}}]}
        """
        try store.ensureDirectory()
        try Data(config.utf8).write(to: store.configURL)
        if !rules.isEmpty {
            try store.saveRules(RulesFile(rules: rules.map { var r = $0; r.topicIds = [topicId]; return r }))
        }
        return topicId
    }

    let high = Rule(name: "high", conditions: [RuleStep("builtin.priority", ["op": .string(">="), "value": .number(4)])],
                    actions: [RuleStep("builtin.popup", ["timeoutSec": .number(0), "position": .string("topRight")]),
                              RuleStep("builtin.playSound", ["name": .string("Basso")])],
                    skipTopicDefaults: true)

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func firstLaunchMigratesOnceAndBacksUp() throws {
        let store = ConfigStore(directory: tempDir())
        let topicId = try writeLegacy(store, rules: [high])
        let legacyConfig = try Data(contentsOf: store.configURL)
        let legacyRules = try Data(contentsOf: store.rulesURL)

        let e = try Engine(store: store, session: StubProtocol.session())
        #expect(e.migrationNotes == ["absorbed rule 'high' into NAS"])
        #expect(try Data(contentsOf: store.backupURL(store.configURL)) == legacyConfig)
        #expect(try Data(contentsOf: store.backupURL(store.rulesURL)) == legacyRules)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.backupURL(store.configURL).path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(e.config.schemaVersion == 2 && e.rules.rules.isEmpty && e.dispatcher.rules.rules.isEmpty)
        #expect(e.config.topic(topicId)?.band(5) == AlertBand(show: .popup, timeoutSec: 0, sound: "Basso"))
        #expect(store.loadConfig().schemaVersion == 2)
        #expect(store.loadRules().rules.isEmpty)
        e.stop()

        let configAfter = try Data(contentsOf: store.configURL)
        let rulesAfter = try Data(contentsOf: store.rulesURL)
        let again = try Engine(store: store, session: StubProtocol.session())
        defer { again.stop() }
        #expect(again.migrationNotes.isEmpty)
        #expect(try Data(contentsOf: store.configURL) == configAfter)
        #expect(try Data(contentsOf: store.rulesURL) == rulesAfter)
    }

    @Test func nothingToAbsorbWritesNoBackups() throws {
        let store = ConfigStore(directory: tempDir())
        let topicId = try writeLegacy(store, rules: [])
        let e = try Engine(store: store, session: StubProtocol.session())
        defer { e.stop() }
        #expect(e.migrationNotes.isEmpty)
        #expect(store.loadConfig().schemaVersion == 2)
        #expect(store.loadConfig().topic(topicId)?.band(3) == AlertBand(show: .notification, timeoutSec: 20))
        #expect(!exists(store.backupURL(store.configURL)) && !exists(store.backupURL(store.rulesURL)))
        #expect(!exists(store.rulesURL))
    }

    @Test func schemaVersion2SkipsMigration() throws {
        let store = ConfigStore(directory: tempDir())
        var c = Config()
        let t = TopicConfig(serverId: c.servers[0].id, topic: "ntfybar-9f3a1c7b2e", label: "NAS")
        c.topics = [t]
        try store.saveConfig(c)
        var rule = high
        rule.topicIds = [t.id]
        try store.saveRules(RulesFile(rules: [rule]))
        let configBytes = try Data(contentsOf: store.configURL)
        let e = try Engine(store: store, session: StubProtocol.session())
        defer { e.stop() }
        #expect(e.migrationNotes.isEmpty && e.rules.rules.count == 1)
        #expect(try Data(contentsOf: store.configURL) == configBytes)
        #expect(!exists(store.backupURL(store.configURL)))
    }
}
