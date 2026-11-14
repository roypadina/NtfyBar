import Foundation
import Testing
@testable import NtfyBarCore

@Suite("Support prompt")
struct SupportPromptTests {
    let day = SupportPromptState.day
    let install = Date(timeIntervalSince1970: 1_794_528_000)  // 2026-11-13

    func state(delivered: Int = 150) -> SupportPromptState {
        var s = SupportPromptState()
        s.installDate = install
        s.delivered = delivered
        return s
    }

    func mayAsk(_ s: SupportPromptState, day d: Double, version: String = "1.6.1") -> Bool {
        s.mayAsk(now: install.addingTimeInterval(d * day), appVersion: version)
    }

    @Test func firstAskNeedsSevenDaysAndMoreThan100Notifications() {
        #expect(!mayAsk(state(), day: 6.9))
        #expect(!mayAsk(state(delivered: 100), day: 30), "never at 100 or fewer, however long installed")
        #expect(mayAsk(state(delivered: 101), day: 7))
        #expect(!mayAsk(SupportPromptState(), day: 30), "no install date yet: never")
    }

    @Test func snoozeHidesFourteenDays() {
        var s = state()
        s.record(.snooze, now: install.addingTimeInterval(10 * day), appVersion: "1.6.1")
        #expect(!mayAsk(s, day: 23.9))
        #expect(mayAsk(s, day: 24))
    }

    @Test func supportQuietFor180Days() {
        var s = state()
        s.record(.support, now: install.addingTimeInterval(10 * day), appVersion: "1.6.1")
        #expect(!mayAsk(s, day: 189))
        #expect(mayAsk(s, day: 190))
    }

    @Test func neverLastsUntilNextMajorAndNinetyDays() {
        var s = state()
        s.record(.never, now: install.addingTimeInterval(10 * day), appVersion: "1.6.1")
        #expect(!mayAsk(s, day: 300, version: "1.7.0"), "a feature release must not undo 'never'")
        #expect(!mayAsk(s, day: 50, version: "2.0.0"), "a major release within 90 days must not undo it")
        #expect(mayAsk(s, day: 100, version: "2.0.0"))
    }

    @Test func atMostThreeAsksPerRolling365Days() {
        var s = state()
        for d in [10.0, 40, 70] { s.recordShown(install.addingTimeInterval(d * day)) }
        #expect(!mayAsk(s, day: 300))
        #expect(mayAsk(s, day: 376), "the first ask has rolled out of the window")
    }

    @Test func oldStateFileStillLoads() throws {
        let store = ConfigStore(directory: tempDir())
        try store.ensureDirectory()
        // 1.6 state.json: no supportPrompt at all; then one with a partial supportPrompt.
        try Data(#"{"lastEventTime":{"srv":1700000000}}"#.utf8).write(to: store.stateURL)
        var s = store.loadState()
        #expect(s.lastEventTime == ["srv": 1_700_000_000], "new keys must not wipe the stream cursor")
        #expect(s.supportPrompt == SupportPromptState())
        #expect(FileManager.default.fileExists(atPath: store.stateURL.path), "not moved aside as corrupt")

        try Data(#"{"lastEventTime":{"srv":5},"supportPrompt":{"delivered":7}}"#.utf8).write(to: store.stateURL)
        s = store.loadState()
        #expect(s.lastEventTime == ["srv": 5])
        #expect(s.supportPrompt.delivered == 7)
        #expect(s.supportPrompt.installDate == nil)
        #expect(s.supportPrompt.shownAt.isEmpty)
    }
}
