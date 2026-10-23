import Foundation
import Testing
@testable import NtfyBarCore

@Suite("Config")
struct ConfigTests {
    @Test func partialFileKeepsEveryOtherDefault() throws {
        let json = #"{"quietHours":{"start":"21:30"},"topics":[{"topic":"ntfybar-9f3a1c7b2e","label":"Builds","notify":"yes"}]}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(c.quietHours.start == "21:30")
        #expect(c.quietHours.end == "09:00")
        #expect(c.quietHours.maxPriority == 4)
        #expect(c.servers.count == 1)
        #expect(c.topics.count == 1)
        #expect(c.topics[0].label == "Builds")
        #expect(c.topics[0].notify == true)  // wrong type → default, not a failed decode
        #expect(c.topics[0].popup.timeoutSec == 20)
        #expect(c.topics[0].retention == Retention(count: 500, days: 30))
    }

    @Test func roundTripsAuthVariants() throws {
        var c = Config()
        c.servers = [ServerConfig(url: "https://a.example", auth: .basic(user: "u", pass: "p")),
                     ServerConfig(url: "https://b.example", auth: .token("tk_x")),
                     ServerConfig(url: "https://c.example")]
        c.pausedUntil = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try ConfigStore.encoder.encode(c)
        let back = try ConfigStore.decoder.decode(Config.self, from: data)
        #expect(back == c)
        #expect(String(decoding: data, as: UTF8.self).contains(#""type" : "basic""#))
    }

    @Test func unknownAuthTypeFallsBackToNone() throws {
        let s = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"url":"https://x.example","auth":{"type":"oauth"}}"#.utf8))
        #expect(s.auth == .none)
    }

    @Test func authHeaders() {
        #expect(ServerAuth.none.headerValue == nil)
        #expect(ServerAuth.basic(user: "testuser", pass: "fakepassword").headerValue == "Basic dGVzdHVzZXI6ZmFrZXBhc3N3b3Jk")
        #expect(ServerAuth.token("tk_abc").headerValue == "Bearer tk_abc")
        #expect(ServerAuth.token("").headerValue == nil)
    }

    @Test(arguments: ["ntfybar-9f3a1c7b2e", "a", "A_b-9", String(repeating: "x", count: 64)])
    func validTopicNames(_ name: String) { #expect(TopicConfig.isValidTopicName(name)) }

    @Test(arguments: ["", "a,b", "a/b", "a?b", "a b", "ä", String(repeating: "x", count: 65), "a\n"])
    func invalidTopicNames(_ name: String) { #expect(!TopicConfig.isValidTopicName(name)) }

    @Test func serverURLValidation() {
        #expect(ServerConfig.validatedURL("https://ntfy.sh/")?.absoluteString == "https://ntfy.sh")
        #expect(ServerConfig.validatedURL("http://192.168.1.5:8080")?.absoluteString == "http://192.168.1.5:8080")
        #expect(ServerConfig.validatedURL("https://ntfy.example/sub")?.absoluteString == "https://ntfy.example/sub")
        #expect(ServerConfig.validatedURL("ftp://ntfy.sh") == nil)
        #expect(ServerConfig.validatedURL("https://user:pw@ntfy.sh") == nil)
        #expect(ServerConfig.validatedURL("https://ntfy.sh?x=1") == nil)
        #expect(ServerConfig.validatedURL("https://ntfy.sh#frag") == nil)
        #expect(ServerConfig.validatedURL("ntfy.sh") == nil)
        #expect(ServerConfig.validatedURL("") == nil)
    }

    @Test func storeWritesMode600InMode700Dir() throws {
        let dir = tempDir().appendingPathComponent("cfg")
        let store = ConfigStore(directory: dir)
        var c = Config()
        c.topics = [TopicConfig(serverId: c.servers[0].id, topic: "ntfybar-9f3a1c7b2e", label: "Demo")]
        try store.saveConfig(c)
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.configURL.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(dirMode == 0o700)
        #expect(store.loadConfig() == c)
    }

    @Test func corruptFileIsMovedAsideNotOverwritten() throws {
        let dir = tempDir()
        let store = ConfigStore(directory: dir)
        try Data("{ not json".utf8).write(to: store.configURL)
        let loaded = store.loadConfig()
        #expect(loaded.topics.isEmpty && loaded.servers.count == 1, "falls back to defaults")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!files.contains("config.json"))
        #expect(files.contains { $0.hasPrefix("config.corrupt-") })
    }

    @Test func envOverridesDirectory() {
        setenv("NTFYBAR_CONFIG_DIR", "/tmp/ntfybar-env-test", 1)
        defer { unsetenv("NTFYBAR_CONFIG_DIR") }
        #expect(ConfigStore.defaultDirectory().path == "/tmp/ntfybar-env-test")
    }

    @Test func pause() {
        var c = Config()
        let now = Date()
        #expect(!c.isPaused(at: now))
        c.pausedUntil = now.addingTimeInterval(60)
        #expect(c.isPaused(at: now))
        c.pausedUntil = .distantFuture
        #expect(c.isPaused(at: now))
        c.pausedUntil = now.addingTimeInterval(-1)
        #expect(!c.isPaused(at: now))
    }
}

@Suite("SafeOpen")
struct SafeOpenTests {
    @Test(arguments: ["https://example.com/x", "http://192.168.1.5:8080/a?b=c"])
    func allows(_ s: String) { #expect(SafeOpen.url(s) != nil) }

    @Test(arguments: ["file:///etc/passwd", "javascript:alert(1)", "shortcuts://run-shortcut?name=x",
                      "x-apple.systempreferences:com.apple.preference.security", "ftp://x.example", "https://", "", "  "])
    func rejects(_ s: String) { #expect(SafeOpen.url(s) == nil) }
}
