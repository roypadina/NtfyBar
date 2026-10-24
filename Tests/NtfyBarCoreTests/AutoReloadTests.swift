import Foundation
import Testing
@testable import NtfyBarCore

/// Edits to config.json / rules.json made outside the app apply without a restart.
@Suite("Auto reload")
@MainActor
struct AutoReloadTests {
    @Test func externalEditsApplyAndBrokenFilesAreIgnored() throws {
        let store = ConfigStore(directory: tempDir())
        try store.saveConfig(Config())
        let e = try Engine(store: store, session: StubProtocol.session())
        e.startWatchingFiles(interval: 3600)  // poll by hand below
        defer { e.stop() }

        // Our own save is not mistaken for an outside change.
        try e.update { $0.quietHours.maxPriority = 3 }
        e.reloadIfChangedOnDisk()
        #expect(e.config.quietHours.maxPriority == 3)

        // An agent adds a topic by rewriting the file.
        var c = e.config
        c.topics.append(TopicConfig(serverId: c.servers[0].id, topic: "ntfybar-9f3a1c7b2e", label: "Added by an agent"))
        try store.saveConfig(c)
        e.reloadIfChangedOnDisk()
        #expect(e.config.topics.map(\.label) == ["Added by an agent"])

        // Half-written file: ignored, settings kept, file left where it is.
        try Data("{ \"topics\": [".utf8).write(to: store.configURL)
        e.reloadIfChangedOnDisk()
        #expect(e.config.topics.count == 1)
        #expect(FileManager.default.fileExists(atPath: store.configURL.path))

        // Rules too.
        try store.saveRules(RulesFile(rules: [Rule(name: "From the file", conditions: [RuleStep("builtin.hasClick")])]))
        e.reloadIfChangedOnDisk()
        #expect(e.rules.rules.map(\.name) == ["From the file"])
        #expect(e.dispatcher.rules.rules.map(\.name) == ["From the file"])
    }
}
