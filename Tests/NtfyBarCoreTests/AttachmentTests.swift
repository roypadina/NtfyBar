import Foundation
import Testing
@testable import NtfyBarCore

@Suite("Attachments")
@MainActor
struct AttachmentTests {
    let server = ServerConfig(url: "https://ntfy.example.com", auth: .token("tk_secret"))

    @Test func configDefaultsAndBackCompat() throws {
        let old = try JSONDecoder().decode(TopicConfig.self, from: Data(#"{"topic":"abc","copyToClipboard":true}"#.utf8))
        #expect(!old.downloadAttachments && !old.copyAttachment && old.copyToClipboard)
        let bad = try JSONDecoder().decode(TopicConfig.self, from: Data(#"{"downloadAttachments":"yes","copyAttachment":true}"#.utf8))
        #expect(!bad.downloadAttachments && bad.copyAttachment)
        var t = TopicConfig(serverId: UUID(), topic: "abc", label: "x")
        t.downloadAttachments = true
        #expect(try JSONDecoder().decode(TopicConfig.self, from: JSONEncoder().encode(t)).downloadAttachments)
    }

    @Test func authOnlyForTheServersOrigin() {
        let expected = "Bearer tk_secret"
        #expect(AttachmentFile.authHeader(for: URL(string: "https://ntfy.example.com/file/abc.jpg")!, server: server) == expected)
        #expect(AttachmentFile.authHeader(for: URL(string: "https://NTFY.example.com:443/file/abc.jpg")!, server: server) == expected)
        #expect(AttachmentFile.authHeader(for: URL(string: "https://other.example.org/a.jpg")!, server: server) == nil)
        #expect(AttachmentFile.authHeader(for: URL(string: "https://ntfy.example.com:8443/a.jpg")!, server: server) == nil)
        #expect(AttachmentFile.authHeader(for: URL(string: "http://ntfy.example.com/a.jpg")!, server: server) == nil, "scheme differs")
        #expect(AttachmentFile.authHeader(for: URL(string: "https://ntfy.example.com.evil.io/a.jpg")!, server: server) == nil)
        let basic = ServerConfig(url: "https://ntfy.example.com", auth: .basic(user: "u", pass: "p"))
        #expect(AttachmentFile.authHeader(for: URL(string: "https://ntfy.example.com/a")!, server: basic)?.hasPrefix("Basic ") == true)
        #expect(AttachmentFile.authHeader(for: URL(string: "https://ntfy.example.com/a")!, server: nil) == nil)
    }

    @Test func downloadRefusesNonHttpURLs() async {
        for u in ["file:///etc/passwd", "ftp://x.example/a", nil] {
            await #expect(throws: (any Error).self) {
                _ = try await AttachmentFile.download(NtfyAttachment(name: "a", url: u), server: nil)
            }
        }
    }

    @Test func nameSanitizing() {
        #expect(AttachmentFile.sanitizedName("photo.jpg") == "photo.jpg")
        #expect(AttachmentFile.sanitizedName("../../etc/passwd") == "passwd")
        #expect(AttachmentFile.sanitizedName("..\\..\\evil.sh") == "evil.sh")
        #expect(AttachmentFile.sanitizedName("..") == "_")
        #expect(AttachmentFile.sanitizedName(".bashrc") == "bashrc")
        #expect(AttachmentFile.sanitizedName("a..b.txt") == "a_b.txt")
        #expect(AttachmentFile.sanitizedName("a/b/") == "b")
        #expect(AttachmentFile.sanitizedName("") == "attachment")
        #expect(AttachmentFile.sanitizedName(nil, fallbackURL: URL(string: "https://x.example/f/pic.png")!) == "pic.png")
        #expect(AttachmentFile.sanitizedName("   ") == "attachment")
        #expect(!AttachmentFile.sanitizedName(String(repeating: "a", count: 500)).isEmpty)
        #expect(AttachmentFile.sanitizedName(String(repeating: "a", count: 500)).count <= 120)
    }

    @Test func openFolderRevealsSavedFileElseFolder() {
        let dir = URL(fileURLWithPath: "/tmp/dl/NtfyBar")
        let file = dir.appendingPathComponent("a.jpg")
        #expect(AttachmentFile.folderAction(saved: file, in: dir) { _ in true } == .reveal(file))
        #expect(AttachmentFile.folderAction(saved: file, in: dir) { _ in false } == .openFolder(dir), "file was deleted")
        #expect(AttachmentFile.folderAction(saved: nil, in: dir) { _ in true } == .openFolder(dir))
        #expect(AttachmentFile.directory.path.hasSuffix("/Downloads/NtfyBar"))
    }

    @Test func uniqueNames() {
        #expect(AttachmentFile.uniqueName("a.jpg") { _ in false } == "a.jpg")
        #expect(AttachmentFile.uniqueName("a.jpg") { $0 == "a.jpg" } == "a (2).jpg")
        #expect(AttachmentFile.uniqueName("a.jpg") { ["a.jpg", "a (2).jpg"].contains($0) } == "a (3).jpg")
        #expect(AttachmentFile.uniqueName("notes") { $0 == "notes" } == "notes (2)")
    }

    // MARK: dispatch

    func dispatch(download: Bool, copyFile: Bool, copyText: Bool, size: Int64? = 1000, attachment: Bool = true) -> [Effect] {
        var c = Config()
        var t = TopicConfig(serverId: c.servers[0].id, topic: "ntfybar-9f3a1c7b2e", label: "Photos")
        t.notify = false
        t.downloadAttachments = download
        t.copyAttachment = copyFile
        t.copyToClipboard = copyText
        c.topics = [t]
        var m = makeMessage(topicId: t.id, body: "An image was shared with you")
        if attachment { m.ntfy.attachment = NtfyAttachment(name: "p.jpg", url: "https://x.example/p.jpg", type: "image/jpeg", size: size) }
        return Dispatcher().handle(m, config: c, now: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func attachmentEffects(_ e: [Effect]) -> [Double?] {
        e.compactMap { if case let .attachment(_, s) = $0 { .some(s) } else { nil } }
    }

    @Test func textThenFileOrdering() {
        let e = dispatch(download: true, copyFile: true, copyText: true)
        let copyIdx = e.firstIndex { if case .copy = $0 { true } else { false } }
        let fileIdx = e.firstIndex { if case .attachment = $0 { true } else { false } }
        #expect(copyIdx != nil && fileIdx != nil && copyIdx! < fileIdx!)
        #expect(attachmentEffects(e) == [1.0])
    }

    @Test func fileOnlyCopiesWithoutGap() {
        #expect(attachmentEffects(dispatch(download: true, copyFile: true, copyText: false)) == [0.0])
        #expect(attachmentEffects(dispatch(download: true, copyFile: false, copyText: true)) == [nil])
    }

    @Test func offByDefaultAndNeedsAttachment() {
        #expect(attachmentEffects(dispatch(download: false, copyFile: true, copyText: true)).isEmpty)
        #expect(attachmentEffects(dispatch(download: true, copyFile: true, copyText: true, attachment: false)).isEmpty)
    }

    @Test func sizeGuardSkipsAutoDownloadOnly() {
        #expect(AttachmentFile.autoDownloadAllowed(size: 100 * 1024 * 1024))
        #expect(!AttachmentFile.autoDownloadAllowed(size: 100 * 1024 * 1024 + 1))
        #expect(AttachmentFile.autoDownloadAllowed(size: nil))
        #expect(attachmentEffects(dispatch(download: true, copyFile: true, copyText: true, size: 200 * 1024 * 1024)).isEmpty)
    }

    @Test func popupButtonsForEveryTopic() {
        var c = Config()
        let t = TopicConfig(serverId: c.servers[0].id, topic: "ntfybar-9f3a1c7b2e", label: "Photos")
        c.topics = [t]
        var m = makeMessage(topicId: t.id)
        m.ntfy.attachment = NtfyAttachment(name: "p.jpg", url: "https://x.example/p.jpg")
        let ids = PopupContent.forMessage(PopupRequest(message: m, label: "x", settings: t.popup)).buttons.map(\.id)
        #expect(ids.contains("attach-copy") && ids.contains("attach-download") && ids.contains("attach-folder"))
        m.ntfy.attachment = NtfyAttachment(name: "p.jpg", url: "file:///etc/passwd")
        #expect(!PopupContent.forMessage(PopupRequest(message: m, label: "x", settings: t.popup)).buttons.map(\.id).contains("attach-copy"))
        m.ntfy.attachment = nil
        #expect(!PopupContent.forMessage(PopupRequest(message: m, label: "x", settings: t.popup)).buttons.map(\.id).contains("attach-download"))
    }
}
