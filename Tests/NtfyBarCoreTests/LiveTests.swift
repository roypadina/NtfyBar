import Foundation
import Testing
@testable import NtfyBarCore

/// Opt-in only (`NTFYBAR_LIVE_TEST=1 swift test --filter Live`), never in CI. Uses a freshly
/// generated throwaway topic on ntfy.sh, an isolated config dir and default priority.
@Suite("Live ntfy.sh", .enabled(if: ProcessInfo.processInfo.environment["NTFYBAR_LIVE_TEST"] == "1"))
@MainActor
final class LiveTests {
    let topic = "ntfybar-test-" + (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    let topicId = UUID()
    var received: [Message] = []
    var effects: [Effect] = []

    func publish(_ text: String) async throws {
        var req = URLRequest(url: URL(string: "https://ntfy.sh")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["topic": topic, "message": text, "priority": 3])
        let (_, resp) = try await URLSession.shared.data(for: req)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test func streamReceivesLiveThenCatchUpAfterReconnect() async throws {
        let store = ConfigStore(directory: tempDir())
        var c = Config()
        c.topics = [TopicConfig(id: topicId, serverId: c.servers[0].id, topic: topic, label: "Live test")]
        try store.saveConfig(c)
        let e = try Engine(store: store, catchUpDebounce: 0.5)
        e.onEffects = { [weak self] in self?.effects += $0 }
        e.start()
        #expect(await eventually(timeout: 10) { e.streamStates.values.first == .connected })

        // Live: must arrive within 5 s (would fail if URLSession buffered the stream for sniffing).
        let sent = Date()
        try await publish("live one")
        #expect(await eventually(timeout: 5) { e.recent.contains { $0.ntfy.message == "live one" } })
        #expect(Date().timeIntervalSince(sent) < 5)
        #expect(e.recent.first?.isCatchUp == false)

        // Disconnect, publish while away, reconnect: the replay arrives as catch-up, summarised.
        e.stop()
        try await Task.sleep(for: .seconds(2))  // ntfy times are whole seconds
        try await publish("while away")
        try await Task.sleep(for: .seconds(1))
        e.start()
        #expect(await eventually(timeout: 10) { e.recent.contains { $0.ntfy.message == "while away" && $0.isCatchUp } })
        #expect(e.history.count() == 2, "the live one replayed via since= was deduped")
        #expect(await eventually(timeout: 3) {
            self.effects.contains(.summaryNotification(topicId: self.topicId, label: "Live test", count: 1))
        })
        e.stop()
    }

    // MARK: publish (v1.3)

    func liveEngine(_ configure: (inout TopicConfig) -> Void = { _ in }) throws -> Engine {
        let store = ConfigStore(directory: tempDir())
        var c = Config()
        var t = TopicConfig(id: topicId, serverId: c.servers[0].id, topic: topic, label: "Live test")
        configure(&t)
        c.topics = [t]
        try store.saveConfig(c)
        return try Engine(store: store, catchUpDebounce: 0.5)
    }

    /// The topic's cached messages as raw JSON objects. ntfy.sh writes its cache in batches, so a
    /// poll right after a publish can be empty: retry for up to 10 s.
    func poll() async throws -> [[String: Any]] {
        for _ in 0..<20 {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "https://ntfy.sh/\(topic)/json?poll=1")!)
            let messages = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            if !messages.isEmpty { return messages }
            try await Task.sleep(for: .milliseconds(500))
        }
        return []
    }

    @Test func fileIsPutWithUTF8FieldsAndItsEchoIsIgnored() async throws {
        let e = try liveEngine()
        e.onEffects = { [weak self] in self?.effects += $0 }
        e.start()
        defer { e.stop() }
        #expect(await eventually(timeout: 10) { e.streamStates.values.first == .connected })
        let url = tempDir().appendingPathComponent("notes.txt")
        try Data("hello file".utf8).write(to: url)
        try await e.send([.file(url)], topicId: topicId, title: "שלום 👋 C++;", tags: ["עבודה"], priority: 3)
        #expect(await eventually(timeout: 10) { e.history.count() == 1 })
        #expect(e.history.recent(limit: 1).first?.read == true, "own echo: stored as read")
        #expect(!effects.contains { if case .notify = $0 { true } else { false } }, "own echo runs nothing")
        let m = try #require(try await poll().first)
        #expect(m["title"] as? String == "שלום 👋 C++;" && m["message"] as? String == "notes.txt")
        #expect(m["tags"] as? [String] == ["ntfybar-mac", "עבודה"])
        let a = try #require(m["attachment"] as? [String: Any])
        #expect(a["name"] as? String == "notes.txt" && (a["size"] as? Int) == 10)
    }

    @Test func longTextArrivesAsTextClipAndIsCopiedAsText() async throws {
        let receiver = try liveEngine { $0.copyToClipboard = true }
        receiver.onEffects = { [weak self] in self?.effects += $0 }
        receiver.start()
        defer { receiver.stop() }
        #expect(await eventually(timeout: 10) { receiver.streamStates.values.first == .connected })
        let sender = try liveEngine()
        let full = String(repeating: "שלום NtfyBar ", count: 400)  // > 4000 B
        try await sender.send([.text(full)], topicId: topicId, title: "Live", tags: [], priority: 3)
        #expect(await eventually(timeout: 15) { self.effects.contains(.copy(full)) })
        let m = try #require(try await poll().first)
        let a = try #require(m["attachment"] as? [String: Any])
        let att = NtfyAttachment(name: a["name"] as? String, url: a["url"] as? String, type: a["type"] as? String,
                                 size: (a["size"] as? NSNumber)?.int64Value)
        #expect(att.name == "clip.txt" && AttachmentFile.isTextClip(att), "\(a)")
        #expect((m["message"] as? String)?.hasSuffix("…") == true)
    }

    @Test func shortTextCarriesTheCopyAction() async throws {
        let e = try liveEngine()
        try await e.send([.text("copy me")], topicId: topicId, title: "Live", tags: [], priority: 3)
        let m = try #require(try await poll().first)
        let actions = try #require(m["actions"] as? [[String: Any]])
        #expect(actions.first?["action"] as? String == "copy" && actions.first?["value"] as? String == "copy me", "\(actions)")
    }
}
