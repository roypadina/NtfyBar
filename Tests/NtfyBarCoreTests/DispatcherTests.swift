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
        t.alerts = AlertBand.expand(notify: true, popup: { var p = PopupSettings(); p.enabled = true; return p }(), soundOverride: nil)
        config.topics = [t]
    }

    func kinds(_ effects: [Effect]) -> [String] {
        effects.map {
            switch $0 {
            case .notify: "notify"
            case .popup: "popup"
            case .pluginPopup: "pluginPopup"
            case .summaryPopup: "summaryPopup"
            case .summaryNotification: "summaryNotification"
            case .floodNotification: "floodNotification"
            case .copy: "copy"
            case .attachment: "attachment"
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

    @Test func floodCollapsesBannersAndPopupsUntilBurstEnds() {
        let d = Dispatcher()
        var log: [[String]] = []
        var summaries: [Int] = []
        for i in 0..<8 {
            let effects = d.handle(makeMessage(topicId: topicId, id: "f\(i)"), config: config, now: now.addingTimeInterval(Double(i)))
            log.append(kinds(effects))
            for e in effects { if case let .summaryPopup(_, _, n) = e { summaries.append(n) } }
        }
        #expect(log.prefix(5).allSatisfy { $0 == ["notify", "popup"] })
        #expect(log[5] == ["floodNotification", "summaryPopup"], "one notice when the burst starts")
        #expect(log[6] == ["summaryPopup"] && log[7] == ["summaryPopup"], "then silence, only the counter")
        #expect(summaries == [1, 2, 3])
        // 10 s of silence ends the burst.
        let after = d.handle(makeMessage(topicId: topicId, id: "late"), config: config, now: now.addingTimeInterval(7 + 10))
        #expect(kinds(after) == ["notify", "popup"])
    }

    @Test func catchUpReplayDoesNotTripTheFloodGuard() {
        let d = Dispatcher()
        for i in 0..<20 { _ = d.handle(makeMessage(topicId: topicId, id: "c\(i)", isCatchUp: true), config: config, now: now) }
        #expect(kinds(d.handle(makeMessage(topicId: topicId, id: "live"), config: config, now: now)) == ["notify", "popup"])
    }

    @Test func processMissedReplayIsFloodGuarded() {
        var c = config
        c.topics[0].processMissed = true
        let d = Dispatcher()
        var all: [String] = []
        for i in 0..<20 { all += kinds(d.handle(makeMessage(topicId: topicId, id: "c\(i)", isCatchUp: true), config: c, now: now)) }
        #expect(all.filter { $0 == "popup" }.count == 5)
        #expect(all.filter { $0 == "floodNotification" }.count == 1)
    }

    @Test func expiredPauseRunsEverything() {
        var c = config
        c.pausedUntil = now.addingTimeInterval(-1)
        #expect(kinds(Dispatcher().handle(makeMessage(topicId: topicId), config: c, now: now)) == ["notify", "popup"])
    }

    @Test func floodGuardWindowIsSliding() {
        var g = FloodGuard()
        for i in 0..<5 { #expect(g.record(topicId, at: now.addingTimeInterval(Double(i) * 3)) == nil) }
        #expect(g.record(topicId, at: now.addingTimeInterval(15)) == nil, "only 4 in the last 10 s")
    }
}
