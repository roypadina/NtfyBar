import Foundation
import Testing
@testable import NtfyBarCore

@Suite("Stream parsing")
struct StreamParserTests {
    @Test func splitsAcrossArbitraryChunks() {
        let text = openLine(time: 10, topic: "a") + "\n" + ntfyLine(id: "m1", time: 11, topic: "a") + "\n"
        let bytes = Array(text.utf8)
        for chunk in [1, 3, 7, 64, bytes.count] {
            var splitter = LineSplitter()
            var lines: [[UInt8]] = []
            var i = 0
            while i < bytes.count {
                lines += splitter.push(Data(bytes[i..<min(i + chunk, bytes.count)]))
                i += chunk
            }
            #expect(lines.count == 2, "chunk \(chunk)")
            #expect(StreamEvent.parse(lines[0]) == .open(time: 10))
            if case let .message(m, _) = StreamEvent.parse(lines[1]) { #expect(m.id == "m1") } else { Issue.record("no message") }
        }
    }

    @Test func nelAndEscapedCRSurviveInsideBody() {
        // Go's encoder emits U+0085 raw; AsyncBytes.lines would split there and drop the message.
        let body = "line1\u{0085}line2\r\nline3\u{2028}end"
        // Built by hand so U+0085 / U+2028 stay raw bytes and \r\n stays a JSON escape.
        let line = #"{"id":"m2","time":1,"event":"message","topic":"a","message":"line1\#u{0085}line2\r\nline3\#u{2028}end"}"#
        #expect(Array(line.utf8).contains(0xC2) && !line.contains("\n"))
        var splitter = LineSplitter()
        let lines = splitter.push(Data((line + "\n").utf8))
        #expect(lines.count == 1)
        guard case let .message(m, raw) = StreamEvent.parse(lines[0]) else { Issue.record("not parsed"); return }
        #expect(m.message == body)
        #expect(raw == line)
    }

    @Test func overlongLineIsDroppedAndNextLineStillParses() {
        var splitter = LineSplitter(maxLineBytes: 100)
        let long = Data(repeating: 0x61, count: 500) + Data([0x0A])
        let next = Data((ntfyLine(id: "ok", time: 1, topic: "a") + "\n").utf8)
        #expect(splitter.push(long).isEmpty)
        let lines = splitter.push(next)
        #expect(lines.count == 1)
    }

    @Test func eventKinds() {
        #expect(StreamEvent.parse(Array(#"{"id":"k","time":5,"event":"keepalive","topic":"a"}"#.utf8)) == .keepalive)
        #expect(StreamEvent.parse(Array(#"{"id":"k","time":5,"event":"message_delete","topic":"a"}"#.utf8)) == .other("message_delete"))
        #expect(StreamEvent.parse(Array(#"{"id":"k","time":5,"event":"future_thing","topic":"a"}"#.utf8)) == .other("future_thing"))
        #expect(StreamEvent.parse(Array("not json".utf8)) == nil)
        #expect(StreamEvent.parse(Array(#"{"time":5,"event":"message"}"#.utf8)) == nil, "id is required")
        #expect(StreamEvent.parse(Array("   ".utf8)) == nil)
        #expect(StreamEvent.parse([]) == nil)
    }

    @Test func toleratesOddFieldTypes() {
        let line = #"{"id":"x","time":5,"event":"message","topic":"a","message":"hi","priority":"high","tags":"nope","click":42}"#
        guard case let .message(m, _) = StreamEvent.parse(Array(line.utf8)) else { Issue.record("dropped"); return }
        #expect(m.message == "hi")
        #expect(m.priorityValue == 3)
        #expect(m.tags == nil)
        #expect(m.click == nil)
    }

    @Test func fullFieldSet() throws {
        let line = """
            {"id":"sPs71M8A2T","time":1643935928,"expires":1643936928,"event":"message","topic":"a","priority":5,
            "tags":["warning","skull"],"click":"https://example.com/i/1","content_type":"text/markdown","icon":"https://example.com/i.png",
            "attachment":{"name":"camera.jpg","type":"image/png","size":33848,"expires":1643946728,"url":"https://example.com/f.png"},
            "actions":[{"action":"view","label":"Open","url":"https://example.com"},{"action":"http","label":"Ack","url":"https://example.com/ack","method":"PUT","headers":{"X-A":"1"},"body":"b","clear":true}],
            "title":"Unauthorized access detected","message":"Movement detected"}
            """.replacingOccurrences(of: "\n", with: "")
        guard case let .message(m, _) = StreamEvent.parse(Array(line.utf8)) else { Issue.record("dropped"); return }
        #expect(m.priorityValue == 5)
        #expect(m.isMarkdown)
        #expect(m.attachment?.size == 33848)
        #expect(m.actions?.count == 2)
        #expect(m.actions?[1].headers?["X-A"] == "1")
        #expect(m.actions?[1].clear == true)
    }

    @Test func backoffSequence() {
        let b = Backoff()
        #expect((0..<8).map { b.delay(attempt: $0, jitter: 0) } == [1, 2, 4, 8, 16, 32, 60, 60])
        for attempt in 0..<10 {
            let d0 = b.delay(attempt: attempt, jitter: 0)
            let d1 = b.delay(attempt: attempt, jitter: 0.999)
            #expect(d1 >= d0 && d1 <= d0 * 1.1)
        }
        #expect(b.delay(attempt: 1000, jitter: 0) == 60)
    }

    @Test func streamURL() {
        let base = URL(string: "https://ntfy.example")!
        #expect(StreamURL.make(server: base, topics: ["a1", "b2"], since: nil)?.absoluteString == "https://ntfy.example/a1,b2/json")
        #expect(StreamURL.make(server: base, topics: ["a1"], since: 1_700_000_000)?.absoluteString
                == "https://ntfy.example/a1/json?since=1700000000")
        #expect(StreamURL.make(server: base, topics: ["ok", "bad/one", "x,y"], since: nil)?.absoluteString == "https://ntfy.example/ok/json")
        #expect(StreamURL.make(server: base, topics: ["bad?"], since: nil) == nil)
        #expect(StreamURL.make(server: URL(string: "http://192.168.1.5:8080/ntfy")!, topics: ["t"], since: nil)?.absoluteString
                == "http://192.168.1.5:8080/ntfy/t/json")
    }

    @Test func catchUpUsesServerTimeOnly() {
        #expect(StreamURL.isCatchUp(messageTime: 99, openTime: 100))
        #expect(!StreamURL.isCatchUp(messageTime: 100, openTime: 100))
        #expect(!StreamURL.isCatchUp(messageTime: 101, openTime: 100))
        #expect(!StreamURL.isCatchUp(messageTime: 1, openTime: nil), "no open event yet → treat as live")
    }
}
