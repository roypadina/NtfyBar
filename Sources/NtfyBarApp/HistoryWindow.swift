import NtfyBarCore
import SwiftUI

@MainActor enum HistoryWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: HistoryView(model: model, engine: model.engine)))
            w.title = "NtfyBar History"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 640, height: 520))
            w.center()
            window = w
            // Release on close: a kept-alive window's view keeps reloading on every new message.
            Task { @MainActor in
                for await _ in NotificationCenter.default.notifications(named: NSWindow.willCloseNotification, object: w) { break }
                if window === w { window = nil }
            }
        }
        if let window { AccessoryWindows.shared.show(window) }
    }
}

struct HistoryView: View {
    let model: AppModel
    let engine: Engine
    @State private var topicFilter: UUID?
    @State private var search = ""
    @State private var limit = 200
    @State private var messages: [Message] = []
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Topic", selection: $topicFilter) {
                    Text("All topics").tag(UUID?.none)
                    ForEach(engine.config.topics) { t in Text(t.displayLabel).tag(Optional(t.id)) }
                }
                .frame(width: 220)
                TextField("Search titles and messages", text: $search).textFieldStyle(.roundedBorder)
                Button("Mark All Read") { engine.markAllRead() }.disabled(engine.unreadCount == 0)
                Button("Clear…") { confirmClear = true }.disabled(messages.isEmpty)
            }
            .padding(10)
            Divider()
            if messages.isEmpty {
                EmptyState(icon: "tray", title: search.isEmpty ? "No messages yet" : "No matches",
                           caption: search.isEmpty ? "Messages from your topics will show up here." : "Try a different search or topic.")
            } else {
                List {
                    ForEach(messages) { m in
                        HistoryRow(message: m, label: model.label(for: m.topicId))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.showRecent(m) }
                            .contextMenu {
                                Button("Show Popup") { model.showRecent(m) }
                                Button("Copy Message") { model.performer.copy(m.body) }
                                if SafeOpen.url(m.ntfy.click) != nil {
                                    Button("Open Link") { model.performer.open(m.ntfy.click) }
                                }
                                Button("Mark Read") { engine.markRead(m) }.disabled(m.read)
                            }
                    }
                    if messages.count >= limit {
                        Button("Load More") { limit += 200; reload() }.frame(maxWidth: .infinity)
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .onAppear(perform: reload)
        .onChange(of: topicFilter) { _, _ in reload() }
        .onChange(of: search) { _, _ in reload() }
        .onChange(of: engine.recent) { _, _ in reload() }
        .onChange(of: engine.unreadCount) { _, _ in reload() }
        .alert(topicFilter == nil ? "Clear all history?" : "Clear this topic's history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) {
                engine.clearHistory(topicId: topicFilter)
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Messages are deleted from this Mac. This can't be undone.")
        }
    }

    private func reload() {
        if !search.isEmpty {
            messages = engine.history.search(search, topicId: topicFilter, limit: limit)
        } else if let topicFilter {
            messages = engine.history.recent(topicId: topicFilter, limit: limit)
        } else {
            messages = engine.history.recent(limit: limit)
        }
    }
}

struct HistoryRow: View {
    let message: Message
    let label: String

    var body: some View {
        let info = PopupContent.priorityInfo(message.priority)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: info.icon)
                .foregroundStyle(Theme.color(info.accent))
                .frame(width: 18)
                .accessibilityLabel("\(info.word) priority")
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    if message.isCatchUp { Text("· while away").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Text(Emoji.prefix(for: message.tags) + (message.title?.isEmpty == false ? message.title! : label))
                    .fontWeight(message.read ? .regular : .semibold)
                if !message.body.isEmpty {
                    Group {
                        if message.ntfy.isMarkdown,
                           let md = try? AttributedString(markdown: message.body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                            Text(md)
                        } else {
                            Text(verbatim: message.body)
                        }
                    }
                    .lineLimit(2).foregroundStyle(.secondary)
                }
            }
            if !message.read {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7).padding(.top, 5).accessibilityLabel("Unread")
            }
        }
        .padding(.vertical, 3)
    }
}
