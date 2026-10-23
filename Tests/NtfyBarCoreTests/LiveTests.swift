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
}
