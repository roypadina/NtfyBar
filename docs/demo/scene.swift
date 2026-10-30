// NtfyBar demo: the real PopupView (PopupPanel.swift + Theme.swift + Components.swift, compiled unchanged) fed by the real Core
// (PopupContent.forMessage, StatusSummary.line) with fake data. Menu rows are copied verbatim from MenuContent in NtfyBarApp.swift;
// the bell is the app's own template glyph (Assets/icons/menubar@2x.png) plus the unread count, as MenuBarLabel draws them.
import AppKit
import NtfyBarCore
import SwiftUI

private let cal = Calendar(identifier: .gregorian)
private func at(_ h: Int, _ m: Int) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: h, minute: m, second: 12))!
}

// MARK: - fake data (public-clean: ntfy.sh, made-up topics, example.com)

private let server = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
private let backupsId = UUID(uuidString: "00000000-0000-4000-8000-0000000000B1")!
private let buildsId = UUID(uuidString: "00000000-0000-4000-8000-0000000000B2")!
private let homeId = UUID(uuidString: "00000000-0000-4000-8000-0000000000B3")!

private let backups: TopicConfig = {
    var t = TopicConfig(id: backupsId, serverId: server, topic: "ntfybar-7b3e95f0c1", label: "Backups")
    t.alerts["5"] = AlertBand(show: .both, timeoutSec: 0, sound: nil)  // "Close the popup after: Stays" for urgent messages (Config.swift AlertBand)
    return t
}()
private let builds = TopicConfig(id: buildsId, serverId: server, topic: "ci-builds", label: "CI builds")
private let home = TopicConfig(id: homeId, serverId: server, topic: "home-server", label: "Home server")
private let config: Config = { var c = Config(); c.topics = [backups, builds, home]; return c }()

private func message(_ topic: TopicConfig, _ id: String, _ title: String, body: String = "", priority: Int = 3, click: String? = nil, minute: Int) -> Message {
    let n = NtfyMessage(id: id, time: Int64(at(9, minute).timeIntervalSince1970), topic: topic.topic, title: title, message: body, priority: priority, click: click)
    return Message(topicId: topic.id, ntfy: n, receivedAt: at(9, minute), isCatchUp: false, read: true, raw: "")
}

// What the curl in the Terminal window sends (README "Usage": curl -H "Title: …" -d "…" ntfy.sh/<topic>).
private let arrived = message(backups, "msg-5", "Backup failed on nas", body: "Disk almost full: 4 GB free. Nightly job skipped.", priority: 5,
                              click: "https://nas.example.com/backups", minute: 41)
private let history: [Message] = [  // engine.recent, newest first (Engine.refreshCounters: history.recent(limit: 8))
    arrived,
    message(builds, "msg-4", "Build 482 passed", minute: 37),
    message(home, "msg-3", "Nightly update finished", minute: 12),
    message(backups, "msg-2", "Backup done", body: "3.1 GB, no errors", minute: 2),
]

// AppModel.swift:77 recentTitle, verbatim (the app looks the label up in its model; here it is passed in).
private func recentTitle(_ m: Message, label: String) -> String {
    let text = (m.title?.isEmpty == false ? m.title! : m.body).replacingOccurrences(of: "\n", with: " ")
    let short = text.count > 60 ? String(text.prefix(57)) + "…" : text
    return "\(label) · \(short)"
}

// MARK: - menu rows (NtfyBarApp.swift MenuContent)

private let states: [UUID: NtfyStream.State] = [backupsId: .connected, buildsId: .connected, homeId: .connected]
private let statusLine = StatusSummary.line(config: config, states: states, now: at(9, 41))  // :62  "Connected · 3 topics"

// Mark All Read is `.disabled(engine.unreadCount == 0)` (:82) and the unread count is 0 once the message was dismissed (EffectPerformer .dismiss -> markRead).
private let menuRows: [MenuMock.Row] = [
    .item(statusLine, enabled: false),                                  // :62  bare Text -> disabled row
    .item("Recent", submenu: true),                                     // :64-65  Menu("Recent"), shown because engine.recent is not empty
    .item("Send Clipboard…"),                                           // :78-79  no last publish topic; the clipboard is not empty
    .item("Publish…"),                                                  // :80
    .item("Mark All Read", enabled: false),                             // :81-82
    .item("Dismiss All Popups"),                                        // :83
    .item("Pause Notifications", submenu: true),                        // :85
    .item("History…"),                                                  // :94
    .separator,                                                         // :96
    .item("Settings…", key: "⌘,"),                                      // :98  OpenSettingsButton, SettingsOpener.swift:72
    .separator,                                                         // :100
    .item("About NtfyBar"),                                             // :102
    .item("Support on Ko-fi ☕"),                                        // :103
    .separator,                                                         // :105
    .item("Quit NtfyBar", key: "⌘Q"),                                   // :107
]
private let recentIndex = 1

private let recentRows: [MenuMock.Row] = [
    .item("Copy Latest Message"),                                       // :67  always
    .item("Open Latest Link"),                                          // :69  only when the latest message has a click URL (it does)
    .separator,                                                         // :71
] + history.map { m in .item(recentTitle(m, label: config.topic(m.topicId)!.displayLabel)) }  // :73-74  one Button per message

// MARK: - status item: MenuBarLabel (template glyph, then the unread count when > 0)

private func glyphSlot(_ width: CGFloat) -> String {  // reserves the glyph's width in the kit's status item; the glyph is drawn over it
    var s = ""
    while (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width < width { s += " " }
    return s
}

private let glyph: CGImage = {  // Assets/icons/menubar@2x.png, tinted like a menu bar template image
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NTFYBAR_ASSETS"]! + "/menubar@2x.png")
    let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    ctx.draw(img, in: r); ctx.setBlendMode(.sourceIn); ctx.setFillColor(CGColor(gray: 1, alpha: 0.95)); ctx.fill(r)
    return ctx.makeImage()!
}()
private let glyphSize: CGFloat = 18  // menubar.png is 18x18 pt

@MainActor private func drawBar(_ c: Canvas, unread: Int, active: Bool = false) -> CGRect {
    let count = unread > 0 ? "\(unread)" : ""  // NtfyBarApp.swift:51 (99+ above 99)
    let f = c.menuBar(app: StatusItem(text: glyphSlot(glyphSize + (unread > 0 ? 3 : 0)) + count), appActive: active, appName: "Terminal", menus: ["Shell", "Edit", "View", "Window", "Help"])  // 3 pt gap as the other apps' HStack labels
    c.draw(glyph, in: CGRect(x: f.minX + 8, y: (Demo.barHeight - glyphSize) / 2, width: glyphSize, height: glyphSize))
    return f
}

// MARK: - the Terminal window (the only element that is not the app: the README's curl pattern in zsh)

private struct TerminalView: View {
    let ran: Bool
    private static let lines = [
        "~ % curl -H \"Title: Backup failed on nas\" \\",
        "> -H \"Priority: urgent\" \\",
        "> -H \"Click: https://nas.example.com/backups\" \\",
        "> -d \"Disk almost full: 4 GB free. Nightly job skipped.\" \\",
        "> ntfy.sh/ntfybar-7b3e95f0c1 > /dev/null",
    ]
    private func line(_ s: String) -> some View { Text(s).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.92)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(Self.lines.enumerated()), id: \.offset) { i, s in
                if !ran && i == Self.lines.count - 1 { HStack(spacing: 0) { line(s); caret } } else { line(s) }
            }
            if ran { HStack(spacing: 0) { line("~ % "); caret } }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.10))
    }
    private var caret: some View { Rectangle().fill(.white.opacity(0.75)).frame(width: 7, height: 14) }
}

// MARK: - a second menu at an explicit origin (submenu): same drawing as the kit's Canvas.menu(_:under:), which only anchors under the status item

extension Canvas {
    @discardableResult
    func submenu(_ rows: [MenuMock.Row], at origin: CGPoint, highlight: Int?, alpha: CGFloat = 1) -> CGRect {
        let frame = CGRect(origin: origin, size: MenuMock.size(rows))
        let path = Canvas.continuousRect(frame, radius: MenuMock.radius)
        ctx.saveGState(); ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        shadow(path, blur: 26, dy: 10, alpha: 0.38)
        material(.menu, path: path)
        if let img = MenuMock.render(rows, highlight: highlight) { draw(img, at: origin) }
        hairline(path, alpha: 0.16)
        ctx.endTransparencyLayer(); ctx.restoreGState()
        return frame
    }
}

// MARK: - geometry helpers

private let W = Demo.size.width, H = Demo.size.height
@MainActor private var popupOrigin: CGPoint { CGPoint(x: W / 2 - PopupPanel.width / 2, y: Demo.barHeight + 12) }  // PopupPanel.frame(for:): top centre, 12 pt margin under the bar
private let terminalSize = CGSize(width: 470, height: 128)
private let terminalOrigin = CGPoint(x: W * 0.07, y: H * 0.56)

@MainActor private func popupImage(flashed: String? = nil) -> CGImage {
    let state = PopupState(PopupContent.forMessage(PopupRequest(message: arrived, label: "Backups", settings: backups.popup.settings(timeoutSec: backups.band(5).timeoutSec))))
    state.flashed = flashed
    return renderView(PopupView(state: state, perform: { _ in }, relayout: {}))!
}

/// Rect (canvas points, relative to the popup image) of the first prominent (accent-filled) button: the Open button. The row is Open, Copy, <spacer>, Dismiss.
private func prominentButton(_ img: CGImage) -> CGRect {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, maxX = -1, minY = h, maxY = -1
    for y in h / 2..<h { for x in 0..<w where x > w / 20 {  // button row = lower half (the header's "Urgent" text and icon share the red); skip the 4 pt signal rim at the left edge
        let i = (y * w + x) * 4
        // Theme.critical dark = (1.00, 0.35, 0.31)
        if px[i + 3] > 250, px[i] > 235, px[i + 1] > 70, px[i + 1] < 110, px[i + 2] > 60, px[i + 2] < 100 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
    } }
    precondition(maxX >= 0, "no prominent button found in the rendered popup")
    return CGRect(x: CGFloat(minX) / Demo.scale, y: CGFloat(minY) / Demo.scale, width: CGFloat(maxX - minX + 1) / Demo.scale, height: CGFloat(maxY - minY + 1) / Demo.scale)
}

@MainActor func ntfyBarScenes() -> [Scene] {
    let popup = popupImage(), popupCopied = popupImage(flashed: "copy")
    let terminalTyped = captureWindow(TerminalView(ran: false), size: terminalSize, title: "demo — -zsh — 58×6")!
    let terminalRan = captureWindow(TerminalView(ran: true), size: terminalSize, title: "demo — -zsh — 58×6")!

    // Popup buttons: Open (prominent, found by colour) first, Copy 8 pt after it, Dismiss right-aligned (PopupView.buttonRow, padding 18).
    let open = prominentButton(popup).offsetBy(dx: popupOrigin.x, dy: popupOrigin.y)
    func buttonWidth(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width) + 28 }  // Theme.button, padding 14
    let copyCenter = CGPoint(x: open.maxX + 8 + buttonWidth("Copy") / 2, y: open.midY)
    let dismissCenter = CGPoint(x: popupOrigin.x + CGFloat(popup.width) / Demo.scale - 18 - buttonWidth("Dismiss") / 2, y: open.midY)

    let item = Canvas(background: nil).menuBar(app: StatusItem(text: glyphSlot(glyphSize)), appName: "Terminal", menus: ["Shell", "Edit", "View", "Window", "Help"])
    let menu = Canvas.menuFrame(menuRows, under: item)
    let rowFrames = MenuMock.frames(menuRows).map { $0.offsetBy(dx: menu.minX, dy: menu.minY) }
    let recentRow = rowFrames[recentIndex]
    let subSize = MenuMock.size(recentRows)
    // The bell sits at the right edge, so the submenu opens to the left of the menu, its first row level with "Recent" (macOS flips submenus that don't fit).
    let subOrigin = CGPoint(x: menu.minX - subSize.width + 4, y: recentRow.minY - MenuMock.pad)
    let subFrames = MenuMock.frames(recentRows).map { $0.offsetBy(dx: subOrigin.x, dy: subOrigin.y) }
    func subRowCenter(_ i: Int) -> CGPoint { CGPoint(x: subOrigin.x + 110, y: subFrames[i].midY) }
    func subHighlight(_ p: CGPoint) -> Int? {
        for (i, f) in subFrames.enumerated() where f.contains(p) { if case .item = recentRows[i] { return i } }
        return nil
    }

    func desktop(_ c: Canvas, ran: Bool) {
        c.window(ran ? terminalRan : terminalTyped, at: terminalOrigin, radius: 16)
    }
    func slide(_ c: Canvas, _ image: CGImage, t: Double, appear: Double) {  // PopupPanel.show: 0.28 s ease-out, 14 pt rise
        let s = easeOut(ramp(t, appear, appear + 0.28))
        if s > 0 { c.panel(image, at: CGPoint(x: popupOrigin.x, y: popupOrigin.y - 14 * (1 - s)), radius: Theme.panelRadius, alpha: CGFloat(s)) }
    }

    // 1. the script: one curl, Return at 1.5 s
    let s1 = Scene(name: "script", duration: 2.4, caption: "One curl from any script sends a message") { t in
        let c = Canvas()
        _ = drawBar(c, unread: 0)
        desktop(c, ran: t >= 1.5)
        return c.image
    }

    // 2. the popup arrives (EffectPerformer.showPopup): the unread count appears with it (Engine.refreshCounters runs before the effects)
    let s2 = Scene(name: "popup", duration: 3.0, caption: "The popup stays on screen until you act") { t in
        let c = Canvas()
        _ = drawBar(c, unread: t >= 0.3 ? 1 : 0)
        desktop(c, ran: true)
        slide(c, popup, t: t, appear: 0.3)
        return c.image
    }

    // 3. Copy flashes "Copied ✓" (1.5 s, popup stays, still unread); Dismiss = markRead + 0.15 s fade -> the count disappears at once
    let path3 = CursorPath(start: CGPoint(x: W * 0.84, y: H * 0.42),
                           moves: [.init(t0: 0.10, t1: 0.75, to: copyCenter),
                                   .init(t0: 1.55, t1: 2.10, to: dismissCenter)],
                           clicks: [0.95, 2.30])
    let s3 = Scene(name: "act", duration: 3.0, caption: "Copy or dismiss. Dismissed counts as read") { t in
        let c = Canvas()
        let dismissed = t >= 2.30
        _ = drawBar(c, unread: dismissed ? 0 : 1)
        desktop(c, ran: true)
        let gone = ramp(t, 2.30, 2.45)
        if gone < 1 { c.panel(t >= 0.95 && t < 2.45 ? popupCopied : popup, at: popupOrigin, radius: Theme.panelRadius, alpha: CGFloat(1 - gone)) }
        let click = path3.click(t)
        c.cursor(at: path3.position(t), alpha: CGFloat(ramp(t, 0.0, 0.25) * (1 - ramp(t, 2.55, 2.80))), press: click.press, pulse: click.pulse)
        return c.image
    }

    // 4. the menu: click opens it at once; hovering "Recent" opens its submenu (to the left); a click on the desktop closes both at once
    let path4 = CursorPath(start: CGPoint(x: W * 0.62, y: H * 0.46),
                           moves: [.init(t0: 0.10, t1: 0.70, to: CGPoint(x: item.midX, y: Demo.barHeight / 2)),
                                   .init(t0: 1.15, t1: 1.65, to: CGPoint(x: menu.minX + 90, y: recentRow.midY)),
                                   .init(t0: 2.10, t1: 2.55, to: subRowCenter(4)),
                                   .init(t0: 3.00, t1: 3.50, to: CGPoint(x: W * 0.36, y: H * 0.50))],
                           clicks: [0.80, 3.70])
    let s4 = Scene(name: "menu", duration: 4.2, caption: "Recent messages stay one click away") { t in
        let c = Canvas()
        let fadeIn = ramp(t, 0.80, 0.92), fadeOut = 1 - ramp(t, 3.70, 3.82)
        let open = t >= 0.80 && fadeOut > 0
        _ = drawBar(c, unread: 0, active: open)
        desktop(c, ran: true)
        if open {
            let p = path4.position(t)
            let sub = t >= 1.85  // macOS opens a submenu a moment after the pointer rests on its row
            c.menu(menuRows, under: item, hover: sub ? CGPoint(x: menu.minX + 90, y: recentRow.midY) : p, alpha: CGFloat(min(fadeIn, fadeOut)))
            if sub { c.submenu(recentRows, at: subOrigin, highlight: subHighlight(p), alpha: CGFloat(fadeOut)) }
        }
        let click = path4.click(t)
        c.cursor(at: path4.position(t), alpha: CGFloat(ramp(t, 0.0, 0.25) * (1 - ramp(t, 3.85, 4.05))), press: click.press, pulse: click.pulse)
        return c.image
    }
    return [s1, s2, s3, s4]
}

@main struct NtfyBarDemo {
    @MainActor static func main() { Demo.run(scenes: ntfyBarScenes()) }
}
