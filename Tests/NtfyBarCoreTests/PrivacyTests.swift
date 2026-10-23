import Foundation
import Testing
@testable import NtfyBarCore

/// Every user-visible string built from a message or the config must leave out the raw topic and
/// the server host.
@Suite("Privacy sweep")
struct PrivacyTests {
    let topic = "ntfybar-9f3a1c7b2e"
    let host = "ntfy.example"

    @Test func visibleStringsNeverNameTopicOrServer() {
        var c = Config()
        c.servers = [ServerConfig(url: "https://\(host)", auth: .token("tk_fake"))]
        c.topics = [TopicConfig(serverId: c.servers[0].id, topic: topic, label: "Builds")]
        let id = c.topics[0].id
        let m = makeMessage(topicId: id, title: "Deploy done", body: "All green", tags: ["tada", "backup"])
        let untitled = makeMessage(topicId: id, title: nil, body: "No title here")
        var strings: [String] = []
        for t in [NotificationText.message(m, label: "Builds"), .message(untitled, label: "Builds"),
                  .catchUp(label: "Builds", count: 3), .flood(label: "Builds")] {
            strings += [t.title, t.subtitle, t.body]
        }
        let states: [NtfyStream.State] = [.connecting, .connected, .reconnecting(at: Date()), .authFailed(status: 401),
                                          .redirected(status: 301), .stopped]
        for st in states { strings.append(StatusSummary.line(config: c, states: [c.servers[0].id: st], now: Date())) }
        c.pausedUntil = .distantFuture
        strings.append(StatusSummary.line(config: c, states: [:], now: Date()))
        for s in strings {
            #expect(!s.contains(topic), "\(s)")
            #expect(!s.contains(host), "\(s)")
        }
    }
}
