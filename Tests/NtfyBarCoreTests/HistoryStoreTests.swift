import Foundation
import Testing
@testable import NtfyBarCore

@Suite("HistoryStore")
@MainActor
struct HistoryStoreTests {
    let dir = tempDir()
    let a = UUID()
    let b = UUID()

    func store() throws -> HistoryStore { try HistoryStore(url: dir.appendingPathComponent("history.sqlite")) }

    @Test func insertDedupesOnTopicAndId() throws {
        let h = try store()
        let m = makeMessage(topicId: a, id: "x1")
        #expect(h.insert(m))
        #expect(!h.insert(m), "same (topicId, id) again")
        #expect(h.insert(makeMessage(topicId: b, id: "x1")), "same id on another topic is a different message")
        #expect(h.count() == 2)
    }

    @Test func fileIsMode600() throws {
        _ = try store()
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("history.sqlite").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func roundTripsMessageFields() throws {
        let h = try store()
        let m = makeMessage(topicId: a, id: "r1", time: 1234, title: "Title", body: "Body", priority: 5, tags: ["warning"],
                            click: "https://example.com", isCatchUp: true)
        h.insert(m)
        let got = try #require(h.recent(topicId: a, limit: 1).first)
        #expect(got.ntfy == m.ntfy)
        #expect(got.isCatchUp)
        #expect(!got.read)
        #expect(got.raw == m.raw)
    }

    @Test func pagingOlderAndNewer() throws {
        let h = try store()
        for t in Int64(1)...10 { h.insert(makeMessage(topicId: a, id: "m\(t)", time: t)) }
        h.insert(makeMessage(topicId: b, id: "other", time: 5))
        #expect(h.recent(topicId: a, limit: 3).map(\.ntfy.time) == [10, 9, 8])
        #expect(h.older(topicId: a, before: 8, limit: 3).map(\.ntfy.time) == [7, 6, 5])
        #expect(h.newer(topicId: a, after: 3, limit: 2).map(\.ntfy.time) == [5, 4], "the 2 right after 3, newest first")
        #expect(h.older(topicId: a, before: 1, limit: 5).isEmpty)
        #expect(h.recent(limit: 100).count == 11)
    }

    @Test func searchMatchesTitleAndBodyAndEscapesWildcards() throws {
        let h = try store()
        h.insert(makeMessage(topicId: a, id: "1", title: "Disk FULL", body: "x"))
        h.insert(makeMessage(topicId: a, id: "2", title: "ok", body: "backup done 100%"))
        h.insert(makeMessage(topicId: b, id: "3", title: "disk", body: "y"))
        #expect(Set(h.search("disk", limit: 10).map(\.ntfy.id)) == ["1", "3"])
        #expect(h.search("disk", topicId: a, limit: 10).map(\.ntfy.id) == ["1"])
        #expect(h.search("100%", limit: 10).map(\.ntfy.id) == ["2"])
        #expect(h.search("%", limit: 10).map(\.ntfy.id) == ["2"], "% is literal")
        #expect(h.search("_", limit: 10).isEmpty, "_ is literal")
    }

    @Test func unreadAndMarkRead() throws {
        let h = try store()
        h.insert(makeMessage(topicId: a, id: "1"))
        h.insert(makeMessage(topicId: a, id: "2"))
        h.insert(makeMessage(topicId: b, id: "3"))
        #expect(h.unreadCount() == 3)
        h.markRead(topicId: a, id: "1")
        #expect(h.unreadCount() == 2)
        #expect(h.unreadCount(topicId: a) == 1)
        h.markRead(topicId: b)
        #expect(h.unreadCount() == 1)
        h.markRead()
        #expect(h.unreadCount() == 0)
    }

    @Test func purgeByCountAndAge() throws {
        let h = try store()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day: Int64 = 86_400
        for i in Int64(0)..<10 { h.insert(makeMessage(topicId: a, id: "n\(i)", time: 1_700_000_000 - i * 60)) }
        h.insert(makeMessage(topicId: a, id: "old", time: 1_700_000_000 - 40 * day))
        h.insert(makeMessage(topicId: b, id: "keep", time: 1_700_000_000 - 40 * day))
        h.purge(topicId: a, keep: 5, days: 30, now: now)
        #expect(h.count(topicId: a) == 5)
        #expect(h.recent(topicId: a, limit: 10).map(\.ntfy.id) == ["n0", "n1", "n2", "n3", "n4"])
        #expect(h.count(topicId: b) == 1, "other topics untouched")
        h.purge(topicId: a, keep: 100, days: 30, now: now.addingTimeInterval(Double(30 * day) + 1))
        #expect(h.count(topicId: a) == 0, "all older than 30 days now")
    }

    @Test func clearTopicOrAll() throws {
        let h = try store()
        h.insert(makeMessage(topicId: a, id: "1"))
        h.insert(makeMessage(topicId: b, id: "2"))
        h.clear(topicId: a)
        #expect(h.count() == 1)
        h.clear()
        #expect(h.count() == 0)
    }

    @Test func persistsAcrossReopen() throws {
        do {
            let h = try store()
            h.insert(makeMessage(topicId: a, id: "p"))
        }
        let h2 = try store()
        #expect(h2.count() == 1)
        #expect(!h2.insert(makeMessage(topicId: a, id: "p")))
    }
}
