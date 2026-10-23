import AppKit
import NtfyBarCore
import SwiftUI

/// A borderless nonactivating NSPanel can never become key by default, which kills keyboard
/// shortcuts on its buttons. Overriding canBecomeKey fixes that WITHOUT calling makeKey ourselves —
/// no focus stealing. Keys only work once the user has clicked into the panel.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PopupState: ObservableObject {
    @Published var content: PopupContent
    @Published var expanded = false
    @Published var hovering = false
    @Published var flashed: String?  // button id that just succeeded (Copied ✓ / Sent ✓)
    @Published var failed: String?

    init(_ content: PopupContent) {
        self.content = content
    }
}

/// Floating, non-activating popups (MeetAlert AlertPanel mechanics): shown with
/// orderFrontRegardless (never steals focus), stacked under the menu bar on the mouse's screen,
/// reflowed on dismiss, closed with `contentView = nil; close()` (orderOut leaks hosting views).
@MainActor
enum PopupPanel {
    typealias Perform = (PopupContent.Button, PopupState) -> Void

    private struct Entry {
        let key: String
        let panel: NSPanel
        let state: PopupState
        var timer: Task<Void, Never>?
    }

    private static var active: [Entry] = []
    static let width: CGFloat = 480
    private static let gap: CGFloat = 10
    private static let margin: CGFloat = 12

    static var count: Int { active.count }

    static func show(_ content: PopupContent, perform: @escaping Perform) {
        if let i = active.firstIndex(where: { $0.key == content.key }) {
            active[i].state.content = content  // e.g. flood counter, plugin reply
            active[i].panel.orderFrontRegardless()
            restartTimer(at: i)
            relayout()
            return
        }
        // No screen (waking from sleep, displays not attached yet): retry instead of losing it.
        guard let screen = screenUnderMouse() else {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                show(content, perform: perform)
            }
            return
        }
        let state = PopupState(content)
        let panel = makePanel(level: content.level)
        panel.contentView = NSHostingView(rootView: PopupView(state: state, perform: { perform($0, state) },
                                                              relayout: { relayout() }))
        let size = fittingSize(panel)
        active.append(Entry(key: content.key, panel: panel, state: state))
        let final = frame(for: active.count - 1, size: size, screen: screen)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = 0
        panel.setFrame(reduce ? final : final.offsetBy(dx: 0, dy: 14), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0.12 : 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
        restartTimer(at: active.count - 1)
    }

    static func dismiss(key: String) {
        guard let i = active.firstIndex(where: { $0.key == key }) else { return }
        remove(at: i)
    }

    static func dismiss(_ state: PopupState) {
        guard let i = active.firstIndex(where: { $0.state === state }) else { return }
        remove(at: i)
    }

    static func dismissAll() {
        while !active.isEmpty { remove(at: 0, animated: false) }
    }

    private static func makePanel(level: PopupSettings.Level) -> NSPanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
                                 styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false  // Swift owns it via `active`
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        switch level {
        case .floating:
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        case .overFullScreen:
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        }
        return panel
    }

    /// Counts down only while the pointer is outside the popup; 0 = stays.
    private static func restartTimer(at i: Int) {
        active[i].timer?.cancel()
        let state = active[i].state
        let seconds = state.content.timeoutSec
        guard seconds > 0 else { active[i].timer = nil; return }
        active[i].timer = Task { @MainActor in
            var left = Double(seconds)
            while left > 0 {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                if !state.hovering { left -= 0.25 }
            }
            dismiss(state)
        }
    }

    private static func remove(at i: Int, animated: Bool = true) {
        let entry = active.remove(at: i)
        entry.timer?.cancel()
        let panel = entry.panel
        let finish = {
            // close, not orderOut: a hidden panel keeps rendering forever (MeetAlert CPU leak)
            panel.contentView = nil
            panel.close()
        }
        guard animated else { finish(); relayout(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                finish()
                relayout()
            }
        })
    }

    private static func fittingSize(_ panel: NSPanel) -> NSSize {
        guard let view = panel.contentView else { return NSSize(width: width, height: 120) }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let maxHeight = (screenUnderMouse()?.visibleFrame.height ?? 800) * 0.8
        return NSSize(width: width, height: min(max(size.height, 60), maxHeight))
    }

    // shortcut: reflow moves every open popup onto the mouse's current screen — right for the
    // common case (one screen of popups); per-popup screens if multi-display stacks matter.
    static func relayout() {
        guard let screen = screenUnderMouse() else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for i in active.indices {
                let size = fittingSize(active[i].panel)
                active[i].panel.animator().setFrame(frame(for: i, size: size, screen: screen), display: true)
            }
        }
    }

    private static func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Stacks downward from the top of the visible frame, per position column; a popup that would
    /// fall off the bottom sits at the lowest fully visible spot instead.
    private static func frame(for index: Int, size: NSSize, screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let position = active[index].state.content.position
        var top = vf.maxY - margin
        for j in 0..<index where active[j].state.content.position == position {
            top -= active[j].panel.frame.height + gap
        }
        let y = max(vf.minY + margin, top - size.height)
        let x = position == .topRight ? vf.maxX - size.width - margin : vf.midX - size.width / 2
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

struct PopupView: View {
    @ObservedObject var state: PopupState
    let perform: (PopupContent.Button) -> Void
    let relayout: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    private var c: PopupContent { state.content }
    private var signal: Color { Theme.color(c.accent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(c.title).font(Theme.title).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(c.blocks.enumerated()), id: \.offset) { _, block in blockView(block) }
            if !c.tags.isEmpty {
                Text(c.tags.joined(separator: " · ")).font(Theme.meta).foregroundStyle(.secondary)
            }
            if let attachment = c.attachment {
                if let url = attachment.url {
                    Link(destination: url) { Label(attachment.label, systemImage: "paperclip") }.font(Theme.meta)
                } else {
                    Label(attachment.label, systemImage: "paperclip").font(Theme.meta).foregroundStyle(.secondary)
                }
            }
            buttons.padding(.top, 2)
        }
        .padding(16)
        .padding(.leading, 6)  // clear the signal rim
        .frame(width: PopupPanel.width, alignment: .topLeading)
        .background(background)
        .onHover { state.hovering = $0 }
        // Every link in the body goes through the same gate as every other open.
        .environment(\.openURL, OpenURLAction { url in
            if SafeOpen.isAllowed(url) { NSWorkspace.shared.open(url) }
            return .handled
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(c.header): \(c.title)")
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let p = c.priority {
                let info = PopupContent.priorityInfo(p)
                Label(info.word, systemImage: info.icon).font(Theme.state).foregroundStyle(signal)
            } else {
                Image(systemName: c.icon).font(Theme.state).foregroundStyle(signal)
            }
            Text(c.header).font(Theme.meta).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if let date = c.date {
                Text(date.formatted(date: .omitted, time: .shortened)).font(Theme.meta).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: PopupContent.Block) -> some View {
        switch block {
        case let .text(text, markdown):
            let long = text.count > 600 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 8
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if markdown, let md = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(md)
                    } else {
                        Text(verbatim: text)
                    }
                }
                .font(Theme.body)
                .lineLimit(state.expanded ? nil : 8)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                if long {
                    Button(state.expanded ? "Show less" : "Show more") {
                        state.expanded.toggle()
                        DispatchQueue.main.async { relayout() }
                    }
                    .buttonStyle(.link).font(Theme.meta)
                }
            }
        case let .keyValue(rows):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.key).font(Theme.meta).foregroundStyle(.secondary)
                        Text(row.value).font(Theme.body).textSelection(.enabled)
                    }
                }
            }
        case let .progress(value, label):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: min(max(value, 0), 1)).tint(signal)
                if let label { Text(label).font(Theme.meta).foregroundStyle(.secondary) }
            }
        case let .badge(text):
            Text(text).font(Theme.state).padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(signal.opacity(0.18)))
                .overlay(Capsule().strokeBorder(signal.opacity(0.5)))
        }
    }

    private var buttons: some View {
        let dismiss = c.buttons.first { $0.action == .dismiss }
        let others = c.buttons.filter { $0.action != .dismiss }
        // The highlighted (Return) button always stays visible, first; the rest fold into a menu
        // as the width requires.
        let primary = others.filter { $0.style == .prominent }
        let rest = others.filter { $0.style != .prominent }
        return ViewThatFits(in: .horizontal) {
            buttonRow(shown: primary + rest, overflow: [], dismiss: dismiss)
            buttonRow(shown: primary + rest.prefix(1), overflow: Array(rest.dropFirst(1)), dismiss: dismiss)
            buttonRow(shown: primary, overflow: rest, dismiss: dismiss)
            buttonRow(shown: [], overflow: others, dismiss: dismiss)
        }
    }

    private func buttonRow(shown: [PopupContent.Button], overflow: [PopupContent.Button], dismiss: PopupContent.Button?) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, b in
                button(b, number: i < 3 ? i + 1 : nil).fixedSize()
            }
            if !overflow.isEmpty {
                Menu("Other actions") {
                    ForEach(overflow) { b in Button(b.label) { perform(b) } }
                }
                .menuStyle(.button)
                .buttonStyle(PopupButtonStyle(signal: signal))
                .fixedSize()
            }
            Spacer(minLength: 0)
            if let dismiss { button(dismiss, number: nil).fixedSize() }
            // ⌘C copies the message; Esc dismisses. Both only once the popup is key (after a click).
            if let text = c.copyText, !text.isEmpty {
                Button("") { perform(PopupContent.Button(id: "copy", label: "Copy", action: .copy(text))) }
                    .keyboardShortcut("c", modifiers: .command).opacity(0).frame(width: 0)
            }
            if let dismiss {
                Button("") { perform(dismiss) }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0)
            }
        }
    }

    @ViewBuilder
    private func button(_ b: PopupContent.Button, number: Int?) -> some View {
        let text = state.flashed == b.id ? (b.id == "copy" ? "Copied ✓" : "Done ✓") : state.failed == b.id ? "Failed ✗" : b.label
        // Sender-defined buttons carry a glyph (↗ opens a link, ⇄ sends a request) and show their host on hover.
        let glyph: String? = b.senderHost == nil ? nil : { if case .http = b.action { "arrow.left.arrow.right" } else { "arrow.up.right" } }()
        let base = Button { perform(b) } label: {
            if let glyph { Label(text, systemImage: glyph) } else { Text(text) }
        }
            .buttonStyle(PopupButtonStyle(signal: b.style == .destructive ? Theme.critical : signal, prominent: b.style == .prominent))
            .help(b.senderHost.map { "From the message: \($0)" } ?? "")
            .accessibilityLabel(b.senderHost.map { "\(b.label), link to \($0)" } ?? b.label)
        if b.style == .prominent {
            base.keyboardShortcut(.defaultAction)
        } else if let number {
            base.keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [])
        } else {
            base
        }
    }

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
        return ZStack(alignment: .leading) {
            if contrast == .increased {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else {
                shape.fill(.regularMaterial)
                shape.fill(Theme.ink)
                if scheme == .dark {
                    shape.fill(RadialGradient(colors: [signal.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 300))
                }
            }
            Rectangle().fill(signal).frame(width: c.accent == .critical ? 6 : Theme.rimWidth)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(contrast == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(signal.opacity(0.55)),
                                    lineWidth: contrast == .increased ? 2 : Theme.strokeWidth))
    }
}

/// Capsule buttons (MeetAlert SignalButtonStyle): `prominent` fills with the accent hue.
struct PopupButtonStyle: ButtonStyle {
    var signal: Color
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(cfg: configuration, signal: signal, prominent: prominent)
    }

    private struct StyledBody: View {
        let cfg: Configuration
        let signal: Color
        let prominent: Bool
        @State private var hover = false

        var body: some View {
            cfg.label
                .font(Theme.button)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .foregroundStyle(prominent ? AnyShapeStyle(Theme.onSignal) : AnyShapeStyle(.primary))
                .background(
                    Capsule()
                        .fill(prominent ? AnyShapeStyle(signal) : AnyShapeStyle(Color.primary.opacity(hover ? 0.14 : 0.08)))
                        .overlay(Capsule().strokeBorder(prominent ? .clear : signal.opacity(hover ? 0.7 : 0.35)))
                )
                .brightness(prominent && hover ? 0.06 : 0)
                .scaleEffect(cfg.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: hover)
                .onHover { hover = $0 }
        }
    }
}
