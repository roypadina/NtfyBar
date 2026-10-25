import AppKit
import NtfyBarCore
import SwiftUI

/// `--render-settings|--render-popup|--render-history|--render-publish <png>`: draws a view with demo data, off
/// screen, for the README and wiki. Uses a throwaway config dir, never the real one, and never
/// connects anywhere. PNGs keep only IHDR/IDAT/IEND (no colour-profile name, no metadata).
@MainActor
enum Renderer {
    static func run(_ flag: String, to url: URL) -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ntfybar-render-\(UUID().uuidString)")
        setenv("NTFYBAR_CONFIG_DIR", dir.path, 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["NTFYBAR_RENDER_DARK"] == "1" ? .darkAqua : .aqua)
        do {
            try DemoData.write(to: ConfigStore(directory: dir))
        } catch {
            FileHandle.standardError.write(Data("NtfyBar: demo data: \(error)\n".utf8))
            return false
        }
        let model = AppModel.shared
        let view: AnyView
        switch flag {
        case "--render-popup":
            view = AnyView(PopupView(state: PopupState(PopupContent.forMessage(DemoData.popupRequest(model.engine))),
                                     perform: { _ in }, relayout: {})
                .padding(24))
        case "--render-history":
            view = AnyView(HistoryView(model: model, engine: model.engine).frame(width: 640, height: 460).background(windowBackground))
        case "--render-publish":
            view = AnyView(PublishView(model: model, engine: model.engine, message: "Build logs from tonight's run.",
                                       files: ["build-482.log", "screenshot.png"].map { URL(fileURLWithPath: "/tmp/\($0)") })
                .frame(width: 500, height: 560).background(windowBackground))
        default:
            let tab = ProcessInfo.processInfo.environment["NTFYBAR_RENDER_TAB"] ?? "topics"
            if tab == "consent", let pkg = model.engine.pluginPackages.first(where: { $0.manifest != nil }) {
                view = AnyView(ConsentSheet(request: ConsentRequest(kind: .package(pkg)), onAllow: {}, onCancel: {}).background(windowBackground))
            } else if tab == "topics-tall", let t = model.engine.config.topics.first {  // the whole editor, unscrolled
                view = AnyView(TopicEditor(model: model, engine: model.engine, draft: t, isNew: false, onRemove: {}) { _ in }
                    .frame(width: 680, height: 1400).background(windowBackground))
            } else if tab == "rules-tall", let r = model.engine.rules.rules.first {
                view = AnyView(RuleEditor(engine: model.engine, draft: r, onRemove: {}) { _ in }.frame(width: 680, height: 1400)
                    .background(windowBackground))
            } else {
                view = AnyView(SettingsView(model: model, engine: model.engine, initialTab: tab).background(windowBackground))
            }
        }
        return write(view, to: url)
    }

    /// A real window paints this behind the tab strip and non-form areas; offscreen they'd be transparent.
    private static let windowBackground = Color(nsColor: .windowBackgroundColor)

    private static func write(_ root: AnyView, to url: URL) -> Bool {
        let host = NSHostingView(rootView: root)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI finish onAppear/state updates before drawing.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try stripPNG(png).write(to: url)
            return true
        } catch {
            FileHandle.standardError.write(Data("NtfyBar: \(error.localizedDescription)\n".utf8))
            return false
        }
    }

    /// Keeps only the IHDR, PLTE, tRNS, IDAT and IEND chunks.
    static func stripPNG(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 8 else { return data }
        var out = Array(bytes[0..<8])
        var i = 8
        while i + 8 <= bytes.count {
            let size = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let kind = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
            let end = min(bytes.count, i + 12 + size)
            if ["IHDR", "PLTE", "tRNS", "IDAT", "IEND"].contains(kind) { out += bytes[i..<end] }
            i = end
        }
        return Data(out)
    }
}

/// Obviously fake demo content for renders. Topics are random-looking placeholders, the server is
/// ntfy.sh plus an example.com host — nothing real.
@MainActor
enum DemoData {
    static let builds = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let home = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let backups = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!

    static func write(to store: ConfigStore) throws {
        var c = Config()
        let selfHosted = ServerConfig(url: "https://ntfy.example.com", auth: .token("tk_demo"))
        c.servers.append(selfHosted)
        var b = TopicConfig(id: builds, serverId: c.servers[0].id, topic: "ntfybar-9f3a1c7b2e", label: "CI builds")
        b.alerts = bands(.both, ["5": (0, "Basso"), "4": (20, "Glass")])
        b.command = CommandSettings(command: "say \"$NTFY_TITLE\"")
        var h = TopicConfig(id: home, serverId: selfHosted.id, topic: "ntfybar-4c81d0e6a2", label: "Home server")
        h.alerts = bands(.popup, ["5": (0, "Sosumi"), "4": (0, "Glass")])
        h.popup.level = .overFullScreen
        let k = TopicConfig(id: backups, serverId: c.servers[0].id, topic: "ntfybar-7b3e95f0c1", label: "Backups")
        c.topics = [b, h, k]
        c.publish.title = "Demo Mac"  // never the real computer name in a screenshot
        c.publish.lastTopicId = home
        try store.saveConfig(c)
        try store.saveRules(RulesFile(rules: [
            Rule(name: "Copy deploy URLs", topicIds: [builds],
                 conditions: [RuleStep("builtin.titleContains", ["needle": .string("deployed")]), RuleStep("builtin.hasClick")],
                 actions: [RuleStep("builtin.copy", ["what": .string("click")])])
        ]))
        let history = try HistoryStore(url: store.historyURL)
        let now = Int64(Date().timeIntervalSince1970)
        for (i, m) in messages.enumerated() {
            let n = NtfyMessage(id: "demo\(i)", time: now - Int64(i) * 2700, topic: "demo", title: m.title, message: m.body,
                                priority: m.priority, tags: m.tags, click: m.click, contentType: "text/markdown")
            let raw = String(decoding: (try? JSONEncoder().encode(n)) ?? Data(), as: UTF8.self)
            history.insert(Message(topicId: m.topic, ntfy: n, receivedAt: Date(timeIntervalSince1970: TimeInterval(n.time)),
                                   isCatchUp: i == 3, read: i > 1, raw: raw))
        }
    }

    /// Five bands showing `show` (20 s, no sound), with per-priority (timeout, sound) overrides.
    private static func bands(_ show: AlertBand.Show, _ overrides: [String: (Int, String)]) -> [String: AlertBand] {
        Dictionary(uniqueKeysWithValues: TopicConfig.priorities.map { p in
            let o = overrides[String(p)]
            return (String(p), AlertBand(show: show, timeoutSec: o?.0 ?? 20, sound: o?.1))
        })
    }

    private static var messages: [(topic: UUID, title: String, body: String, priority: Int, tags: [String], click: String?)] {
        [
            (home, "Disk almost full", "Volume 1 is at **94%**. The nightly snapshot may fail.", 5, ["warning", "nas"], "https://example.com/storage"),
            (builds, "main deployed", "Build #482 passed and went live in 3 m 12 s.", 3, ["white_check_mark"], "https://example.com/builds/482"),
            (backups, "Backup finished", "1,204 files, 3.1 GB, no errors.", 2, ["floppy_disk"], nil),
            (home, "Door sensor offline", "Front door sensor hasn't reported for 15 minutes.", 4, ["door"], nil),
            (builds, "Tests failed on feature-branch", "2 of 318 tests failed: SyncTests.testRetry, SyncTests.testBackoff.", 4, ["x"], "https://example.com/builds/481")
        ]
    }

    static func popupRequest(_ engine: Engine) -> PopupRequest {
        let n = NtfyMessage(id: "demo-popup", time: Int64(Date().timeIntervalSince1970), topic: "demo", title: "Disk almost full",
                            message: "Volume 1 is at **94%**. The nightly snapshot may fail — free up space or extend the volume.",
                            priority: 5, tags: ["warning", "nas"], click: "https://example.com/storage",
                            actions: [NtfyAction(action: "view", label: "Open dashboard", url: "https://example.com/storage"),
                                      NtfyAction(action: "http", label: "Start cleanup", url: "https://example.com/api/cleanup", clear: true)],
                            contentType: "text/markdown")
        let m = Message(topicId: home, ntfy: n, receivedAt: Date(), isCatchUp: false, raw: "{}")
        let s = engine.config.topic(home)?.popup.settings(timeoutSec: 0) ?? PopupSettings()
        return PopupRequest(message: m, label: "Home server", settings: s)
    }
}
