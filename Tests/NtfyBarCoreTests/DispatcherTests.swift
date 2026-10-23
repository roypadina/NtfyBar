import Foundation
import Testing
@testable import NtfyBarCore

@Suite("Dispatcher")
@MainActor
struct DispatcherTests {
    var config = Config()
    let topicId = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    init() {
        var t = TopicConfig(id: topicId, serverId: config.servers[0].id, topic: "ntfybar-9f3a1c7b2e", label: "Builds")
        t.popup.enabled = true
        config.topics = [t]
    }

    func kinds(_ effects: [Effect]) -> [String] {
        effects.map {
            switch $0 {
            case .notify: "notify"
            case .popup: "popup"
            case .summaryPopup: "summaryPopup"
            case .summaryNotification: "summaryNotification"
            case .copy: "copy"
            case .playSound: "sound"
            case .runCommand: "command"
            case .runShortcut: "shortcut"
            case .openURL: "open"
            case .publish: "publish"
            }
        }
    }

    @Test func liveMessageRunsTopicDefaults() {
        var c = config
        c.topics[0].copyToClipboard = true
        c.topics[0].command = CommandSettings(command: "echo hi")
        let d = Dispatcher()
        let effects = d.handle(makeMessage(topicId: topicId, priority: 5), config: c, now: now)
        #expect(kinds(effects) == ["notify", "popup", "sound", "copy", "command"])
        #expect(effects.contains(.playSound("Basso")))
    }

    @Test func unknownTopicDoesNothing() {
        #expect(Dispatcher().handle(makeMessage(topicId: UUID()), config: config, now: now).isEmpty)
    }

    @Test func catchUpIsSummarisedOnce() {
        let d = Dispatcher()
        for i in 0..<4 {
            #expect(d.handle(makeMessage(topicId: topicId, id: "c\(i)", isCatchUp: true), config: config, now: now).isEmpty)
        }
        #expect(d.flushCatchUp(config: config, now: now) == [.summaryNotification(topicId: topicId, label: "Builds", count: 4)])
        #expect(d.flushCatchUp(config: config, now: now).isEmpty, "flushed once")
    }

    @Test func processMissedTreatsCatchUpAsLive() {
        var c = config
        c.topics[0].processMissed = true
        let d = Dispatcher()
        #expect(kinds(d.handle(makeMessage(topicId: topicId, isCatchUp: true), config: c, now: now)) == ["notify", "popup"])
        #expect(d.flushCatchUp(config: c, now: now).isEmpty)
    }

    @Test func pauseKeepsOnlyQuietEffects() {
        var c = config
        c.topics[0].copyToClipboard = true
        c.topics[0].command = CommandSettings(command: "echo hi")
        c.pausedUntil = now.addingTimeInterval(600)
        let d = Dispatcher()
        #expect(kinds(d.handle(makeMessage(topicId: topicId, priority: 5), config: c, now: now)) == ["copy"])
        _ = d.handle(makeMessage(topicId: topicId, isCatchUp: true), config: c, now: now)
        #expect(d.flushCatchUp(config: c, now: now).isEmpty, "no summary while paused")
    }

    @Test func floodCollapsesPopupsUntilBurstEnds() {
        let d = Dispatcher()
        var popups = 0
        var summaries: [Int] = []
        for i in 0..<8 {
            let effects = d.handle(makeMessage(topicId: topicId, id: "f\(i)"), config: config, now: now.addingTimeInterval(Double(i)))
            for e in effects {
                if case .popup = e { popups += 1 }
                if case let .summaryPopup(_, _, n) = e { summaries.append(n) }
            }
            #expect(effects.contains { if case .notify = $0 { true } else { false } }, "notifications keep coming")
        }
        #expect(popups == 5)
        #expect(summaries == [1, 2, 3])
        // 10 s of silence ends the burst.
        let after = d.handle(makeMessage(topicId: topicId, id: "late"), config: config, now: now.addingTimeInterval(7 + 10))
        #expect(kinds(after).contains("popup"))
    }

    @Test func floodGuardWindowIsSliding() {
        var g = FloodGuard()
        for i in 0..<5 { #expect(g.record(topicId, at: now.addingTimeInterval(Double(i) * 3)) == nil) }
        #expect(g.record(topicId, at: now.addingTimeInterval(15)) == nil, "only 4 in the last 10 s")
    }
}
