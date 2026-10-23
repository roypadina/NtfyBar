import Foundation
import Testing
@testable import NtfyBarCore

@Suite("Status line")
struct StatusSummaryTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func config(topics: Int) -> Config {
        var c = Config()
        c.topics = (0..<topics).map { TopicConfig(serverId: c.servers[0].id, topic: "ntfybar-demo-\($0)", label: "T\($0)") }
        return c
    }

    @Test func states() {
        let s = UUID()
        #expect(StatusSummary.line(config: config(topics: 0), states: [:], now: now) == "No topics yet — add one in Settings")
        #expect(StatusSummary.line(config: config(topics: 2), states: [s: .connected], now: now) == "Connected · 2 topics")
        #expect(StatusSummary.line(config: config(topics: 1), states: [s: .connecting], now: now) == "Connecting…")
        #expect(StatusSummary.line(config: config(topics: 1), states: [s: .reconnecting(at: now)], now: now) == "Reconnecting…")
        #expect(StatusSummary.line(config: config(topics: 1), states: [s: .authFailed(status: 401), UUID(): .connected], now: now)
                == "Sign-in failed — check Settings › Servers")
    }

    @Test func pausedPrefix() {
        var c = config(topics: 1)
        c.pausedUntil = .distantFuture
        #expect(StatusSummary.line(config: c, states: [UUID(): .connected], now: now) == "Paused until resumed · Connected · 1 topic")
    }

    @Test func neverContainsTopicName() {
        let c = config(topics: 3)
        let line = StatusSummary.line(config: c, states: [UUID(): .connected], now: now)
        #expect(!c.topics.contains { line.contains($0.topic) })
    }

    @Test func emojiPrefix() {
        #expect(Emoji.prefix(for: ["warning", "skull", "backup"]) == "⚠️💀 ")
        #expect(Emoji.prefix(for: ["backup"]) == "")
        #expect(Emoji.plainTags(["warning", "backup"]) == ["backup"])
        #expect(Emoji.emoji(for: "+1") == "👍")
    }
}
