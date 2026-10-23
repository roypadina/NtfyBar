import NtfyBarCore
import SwiftUI

struct TopicsTab: View {
    let model: AppModel
    let engine: Engine
    @State private var selection: UUID?
    @State private var draft: TopicConfig?
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(engine.config.topics) { t in
                        HStack {
                            Text(t.displayLabel)
                            Spacer()
                            if !t.enabled { Text("Off").font(.caption).foregroundStyle(.secondary) }
                        }
                        .tag(t.id)
                    }
                }
                HStack {
                    Button { addTopic() } label: { Image(systemName: "plus") }
                    Button { confirmDelete = true } label: { Image(systemName: "minus") }.disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(8)
            }
            .frame(width: 210)
            Divider()
            if let draft {
                TopicEditor(model: model, engine: engine, draft: draft, isNew: true) { saved in
                    self.draft = nil
                    selection = saved
                }
                .id("new")
            } else if let id = selection, let topic = engine.config.topic(id) {
                TopicEditor(model: model, engine: engine, draft: topic, isNew: false) { _ in }.id(id)
            } else {
                VStack(spacing: 8) {
                    Text(engine.config.topics.isEmpty ? "No topics yet." : "Select a topic.").font(.headline)
                    Text("Add a topic with +. Use the same topic name as in the ntfy app on your phone.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = engine.config.topics.first?.id } }
        .alert("Remove this topic?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) { removeSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("NtfyBar stops listening to it and deletes its message history.")
        }
    }

    private func addTopic() {
        guard let server = engine.config.servers.first else { return }
        selection = nil
        draft = TopicConfig(serverId: server.id, topic: "", label: "")
    }

    private func removeSelected() {
        guard let id = selection else { return }
        try? engine.update { $0.topics.removeAll { $0.id == id } }
        engine.clearHistory(topicId: id)
        try? engine.updateRules { rules in
            for i in rules.indices { rules[i].topicIds.removeAll { $0 == id } }
        }
        selection = engine.config.topics.first?.id
    }
}

struct TopicEditor: View {
    let model: AppModel
    let engine: Engine
    @State var draft: TopicConfig
    let isNew: Bool
    let onDone: (UUID?) -> Void
    @State private var error: String?
    @State private var status: String?
    @State private var commandOn = false

    var body: some View {
        Form {
            Section {
                TextField("Label", text: $draft.label, prompt: Text("Shown in menus and popups"))
                Picker("Server", selection: $draft.serverId) {
                    ForEach(engine.config.servers) { s in
                        Text(ServerConfig.validatedURL(s.url)?.host() ?? s.url).tag(s.id)
                    }
                }
                HStack {
                    TextField("Topic", text: $draft.topic, prompt: Text("e.g. ntfybar-k3Xq9Lw2…"))
                        .font(.system(.body, design: .monospaced))
                    Button("Random") { draft.topic = TopicConfig.randomName() }
                }
                Toggle("Enabled", isOn: $draft.enabled)
            } header: {
                Text("Subscription")
            } footer: {
                Text("Anyone who knows a topic name on a public server can read and send to it. Pick a long random one — and keep it out of screenshots.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("When a message arrives") {
                Toggle("Show a macOS notification", isOn: $draft.notify)
                Toggle("Show NtfyBar's popup", isOn: $draft.popup.enabled)
                if draft.popup.enabled {
                    Stepper("Close after \(draft.popup.timeoutSec == 0 ? "never (stays)" : "\(draft.popup.timeoutSec) s")",
                            value: $draft.popup.timeoutSec, in: 0...600, step: 5)
                    Toggle("Urgent messages stay until dismissed", isOn: $draft.popup.stickyForUrgent)
                    Picker("Show over", selection: $draft.popup.level) {
                        Text("Normal windows").tag(PopupSettings.Level.floating)
                        Text("Full-screen apps too").tag(PopupSettings.Level.overFullScreen)
                    }
                    Picker("Position", selection: $draft.popup.position) {
                        Text("Top center").tag(PopupSettings.Position.topCenter)
                        Text("Top right").tag(PopupSettings.Position.topRight)
                    }
                    Toggle("Copy button", isOn: $draft.popup.showCopy)
                    Toggle("Open button (click URL)", isOn: $draft.popup.showOpen)
                    TextField("Sound for urgent", text: soundBinding("5"), prompt: Text("none"))
                    TextField("Sound for high", text: soundBinding("4"), prompt: Text("none"))
                }
                Toggle("Copy the message to the clipboard", isOn: $draft.copyToClipboard)
                Toggle("Run a command", isOn: $commandOn)
                if commandOn {
                    TextField("Command", text: commandBinding, prompt: Text("say \"$NTFY_TITLE\""), axis: .vertical)
                        .font(.system(.body, design: .monospaced)).lineLimit(1...4)
                    Stepper("Time limit \(draft.command?.timeoutSec ?? 30) s", value: Binding(
                        get: { draft.command?.timeoutSec ?? 30 }, set: { draft.command?.timeoutSec = $0 }), in: 1...600)
                    Toggle("Notify me when it fails", isOn: Binding(
                        get: { draft.command?.notifyOnFailure ?? true }, set: { draft.command?.notifyOnFailure = $0 }))
                    Text("Runs with /bin/zsh in your home folder. The message arrives in $NTFY_MESSAGE, $NTFY_TITLE, $NTFY_PRIORITY, $NTFY_TAGS, $NTFY_CLICK, $NTFY_ID, $NTFY_TIME, $NTFY_JSON and on stdin — never pasted into the command itself. Quote them (\"$NTFY_TITLE\") and don't hand them to eval or osascript -e.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Also run all this for messages missed while away", isOn: $draft.processMissed)
            }

            Section("History") {
                Stepper("Keep the last \(draft.retention.count) messages", value: $draft.retention.count, in: 10...10_000, step: 50)
                Stepper("…for at most \(draft.retention.days) days", value: $draft.retention.days, in: 1...365)
            }

            Section {
                HStack {
                    Button("Send Test Message", action: sendTest).disabled(isNew)
                    if let status { Text(status).foregroundStyle(.secondary) }
                    Spacer()
                    if let error { Text(error).foregroundStyle(.red) }
                    Button("Save", action: save).keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { commandOn = draft.command != nil }
        .onChange(of: commandOn) { _, on in
            if on && draft.command == nil { draft.command = CommandSettings(command: "") }
            if !on { draft.command = nil }
        }
    }

    private var commandBinding: Binding<String> {
        Binding(get: { draft.command?.command ?? "" }, set: { draft.command?.command = $0 })
    }

    private func soundBinding(_ priority: String) -> Binding<String> {
        Binding(get: { draft.popup.soundByPriority[priority] ?? "" },
                set: { draft.popup.soundByPriority[priority] = $0.isEmpty ? nil : $0 })
    }

    private func save() {
        draft.topic = draft.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.label = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TopicConfig.isValidTopicName(draft.topic) else {
            error = "Topic: 1–64 letters, digits, - or _."
            return
        }
        guard !draft.label.isEmpty else {
            error = "Give the topic a label."
            return
        }
        let t = draft
        guard !engine.config.topics.contains(where: { $0.id != t.id && $0.serverId == t.serverId && $0.topic == t.topic }) else {
            error = "You already subscribe to this topic on this server."
            return
        }
        if t.command?.command.trimmingCharacters(in: .whitespaces).isEmpty == true { draft.command = nil }
        let topic = draft
        try? engine.update { c in
            if let i = c.topics.firstIndex(where: { $0.id == topic.id }) { c.topics[i] = topic } else { c.topics.append(topic) }
        }
        error = nil
        status = "Saved"
        onDone(topic.id)
    }

    private func sendTest() {
        status = "Sending…"
        let req = PublishRequest(topicId: draft.id, title: "NtfyBar test", message: "Test message from NtfyBar Settings.", priority: 3,
                                 tags: ["white_check_mark"])
        Task { @MainActor in
            do {
                try await engine.publish(req, rateKey: "test")
                status = "Sent"
            } catch {
                status = "Failed: \(String(describing: error))"
            }
        }
    }
}
