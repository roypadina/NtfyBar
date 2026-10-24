import AppKit
import NtfyBarCore
import SwiftUI

@MainActor enum PublishWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PublishView(model: model, engine: model.engine)))
            w.title = "Publish"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 500, height: 560))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Compose one send to one topic: the message goes first, then each file as its own message.
struct PublishView: View {
    let model: AppModel
    let engine: Engine
    @State private var topicId: UUID?
    @State private var title: String
    @State private var tags = ""
    @State private var priority = 3
    @State private var message: String
    @State private var files: [URL]
    @State private var status = ""
    @State private var failed = false
    @State private var sending = false

    init(model: AppModel, engine: Engine, message: String = "", files: [URL] = []) {
        self.model = model
        self.engine = engine
        _title = State(initialValue: engine.config.publish.title)
        _message = State(initialValue: message)
        _files = State(initialValue: files)
    }

    private var topics: [TopicConfig] { engine.config.topics.filter(\.enabled) }
    private var text: String { message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : message }

    var body: some View {
        Form {
            Section {
                Picker("Topic", selection: $topicId) {
                    if topics.isEmpty { Text("No topics — add one in Settings").tag(UUID?.none) }
                    ForEach(topics) { t in Text(t.displayLabel).tag(Optional(t.id)) }
                }
                TextField("Title", text: $title)
                TextField("Tags", text: $tags, prompt: Text("extra, comma-separated"))
                Picker("Priority", selection: $priority) {
                    ForEach(1...5, id: \.self) { p in Text("\(p) · \(PopupContent.priorityInfo(p).word)").tag(p) }
                }
            }
            Section("Message") {
                TextEditor(text: $message)
                    .font(.body)
                    .frame(minHeight: 110)
                    .accessibilityLabel("Message")
            }
            Section {
                if files.isEmpty {
                    Text("Drop files here, or Add…").foregroundStyle(.secondary)
                }
                ForEach(files, id: \.self) { url in
                    HStack {
                        Image(systemName: "doc")
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { files.removeAll { $0 == url } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(url.lastPathComponent)")
                    }
                }
            } header: {
                HStack {
                    Text("Files")
                    Spacer()
                    Button("Add…", action: addFiles)
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(status).foregroundStyle(failed ? Color.red : Color.secondary).lineLimit(2)
                Spacer()
                Button("Send", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(sending || topicId == nil || (text.isEmpty && files.isEmpty))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .frame(minWidth: 440, minHeight: 500)
        .dropDestination(for: URL.self) { urls, _ in
            let new = urls.filter { $0.isFileURL && !files.contains($0) }
            files += new
            return !new.isEmpty
        }
        .onAppear {
            if topicId == nil || !topics.contains(where: { $0.id == topicId }) {
                topicId = model.lastPublishTopic?.id ?? topics.first?.id
            }
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            files += panel.urls.filter { !files.contains($0) }
        }
    }

    private func send() {
        guard let topicId else { return }
        let items = (text.isEmpty ? [] : [Outgoing.text(text)]) + files.map(Outgoing.file)
        let extraTags = tags.split(separator: ",").map(String.init)
        sending = true
        failed = false
        status = "Sending…"
        Task {
            let result = await model.send(items, topicId: topicId, title: title, tags: extraTags, priority: priority)
            sending = false
            failed = !result.ok
            status = result.text
            if result.ok {
                message = ""
                files = []
            }
        }
    }
}
