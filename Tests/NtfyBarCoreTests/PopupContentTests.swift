import Foundation
import Testing
@testable import NtfyBarCore

@Suite("Popup content")
struct PopupContentTests {
    let topicId = UUID()

    func request(priority: Int? = 3, actions: [NtfyAction]? = nil, click: String? = nil, settings: PopupSettings = PopupSettings(),
                 extra: [PopupButton] = [], tags: [String]? = nil, attachment: NtfyAttachment? = nil, markdown: Bool = false) -> PopupRequest {
        var n = NtfyMessage(id: "p1", time: 1_700_000_000, topic: "ntfybar-9f3a1c7b2e", title: "Title", message: "Body", priority: priority,
                            tags: tags, click: click, actions: actions, attachment: attachment, contentType: markdown ? "text/markdown" : nil)
        n.event = "message"
        return PopupRequest(message: Message(topicId: topicId, ntfy: n, receivedAt: Date(), isCatchUp: false, raw: "{}"),
                            label: "Builds", settings: settings, extraButtons: extra)
    }

    func ids(_ c: PopupContent) -> [String] { c.buttons.map(\.id) }

    @Test func ntfyActionsBecomeButtonsSafely() {
        let actions = [NtfyAction(action: "view", label: "Docs", url: "https://example.com/d"),
                       NtfyAction(action: "view", label: "Evil", url: "file:///etc/passwd"),
                       NtfyAction(action: "broadcast", label: "Android only"),
                       NtfyAction(action: "http", label: "Ack", url: "https://example.com/ack", clear: true)]
        let c = PopupContent.forMessage(request(actions: actions))
        // Only the first three actions are considered (ntfy's limit); file: and broadcast are dropped.
        #expect(ids(c) == ["ntfy-0", "copy", "dismiss"])
        let four = PopupContent.forMessage(request(actions: [actions[0], actions[3]]))
        #expect(ids(four) == ["ntfy-0", "ntfy-1", "copy", "dismiss"])
        #expect(four.buttons[1].action == .http(actions[3]) && four.buttons[1].clears)
    }

    @Test func exactlyOneProminentButton() {
        func prominent(_ c: PopupContent) -> [String] { c.buttons.filter { $0.style == .prominent }.map(\.id) }
        #expect(prominent(.forMessage(request(actions: [NtfyAction(action: "view", label: "V", url: "https://example.com")], click: "https://example.com"))) == ["open"])
        // A sender-defined action is never the Return button, even as the only action.
        let http = NtfyAction(action: "http", label: "Dismiss", url: "http://192.168.1.1/reboot")
        let onlyHttp = PopupContent.forMessage(request(actions: [http]))
        #expect(prominent(onlyHttp) == ["dismiss"])
        #expect(onlyHttp.buttons.first?.senderHost == "192.168.1.1", "shown with its host")
        #expect(prominent(.forMessage(request(click: "https://example.com"))) == ["open"])
        #expect(prominent(.forMessage(request())) == ["dismiss"])
        var s = PopupSettings()
        s.showCopy = false
        s.showOpen = false
        #expect(ids(.forMessage(request(click: "https://example.com", settings: s))) == ["dismiss"])
    }

    @Test func openOnlyForHttpClick() {
        #expect(!ids(.forMessage(request(click: "shortcuts://run-shortcut?name=x"))).contains("open"))
        #expect(ids(.forMessage(request(click: "https://example.com"))).contains("open"))
    }

    @Test func urgentIsStickyWhenConfigured() {
        var s = PopupSettings()
        s.timeoutSec = 15
        #expect(PopupContent.forMessage(request(priority: 5, settings: s)).timeoutSec == 0)
        #expect(PopupContent.forMessage(request(priority: 4, settings: s)).timeoutSec == 15)
        s.stickyForUrgent = false
        #expect(PopupContent.forMessage(request(priority: 5, settings: s)).timeoutSec == 15)
    }

    @Test func priorityIsWordIconAndAccent() {
        let c = PopupContent.forMessage(request(priority: 5))
        #expect(c.accent == .critical && c.icon == "exclamationmark.triangle.fill")
        #expect(PopupContent.priorityInfo(5).word == "Urgent" && PopupContent.priorityInfo(1).word == "Min")
    }

    @Test func titleTagsAttachmentAndMarkdown() {
        let c = PopupContent.forMessage(request(tags: ["warning", "nas"],
                                                attachment: NtfyAttachment(name: "cam.jpg", url: "https://example.com/f.jpg", size: 33_848),
                                                markdown: true))
        #expect(c.title == "⚠️ Title")
        #expect(c.tags == ["nas"])
        #expect(c.attachment?.label.hasPrefix("cam.jpg · ") == true)
        #expect(c.attachment?.url?.absoluteString == "https://example.com/f.jpg")
        #expect(c.blocks == [.text("Body", markdown: true)])
        #expect(c.header == "Builds", "label, never the topic")
        let badAttachment = PopupContent.forMessage(request(attachment: NtfyAttachment(name: "x", url: "file:///etc/passwd")))
        #expect(badAttachment.attachment?.url == nil)
    }

    @Test func ruleButtons() {
        let c = PopupContent.forMessage(request(extra: [PopupButton(id: "rule-button", label: "Dash", openURL: "https://example.com/d"),
                                                        PopupButton(id: "bad", label: "Bad", openURL: "javascript:alert(1)")]))
        #expect(ids(c) == ["rule-button", "copy", "dismiss"])
    }

    @Test func floodPopup() {
        let c = PopupContent.flood(topicId: topicId, label: "Builds", count: 7)
        #expect(c.key == "flood-\(topicId.uuidString)" && c.title == "7 more messages" && c.timeoutSec == 0)
        #expect(c.buttons.map(\.action) == [.showHistory, .dismiss])
    }
}
