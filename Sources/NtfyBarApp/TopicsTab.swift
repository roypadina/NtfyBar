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
            SidebarPane(selection: $selection, onAdd: addTopic, onRemove: { confirmDelete = true }, removeDisabled: selection == nil) {
                ForEach(engine.config.topics) { t in
                    // Subtitle is the plan, never the topic name (a secret).
                    SidebarRow(enabled: t.enabled, title: t.displayLabel, subtitle: planSummary(t)).tag(t.id)
                }
            } extraButtons: { EmptyView() }
            Divider()
            if let draft {
                TopicEditor(model: model, engine: engine, draft: draft, isNew: true) { saved in
                    self.draft = nil
                    selection = saved
                }
                .id("new")
            } else if let id = selection, let topic = engine.config.topic(id) {
                TopicEditor(model: model, engine: engine, draft: topic, isNew: false, onRemove: { confirmDelete = true }) { _ in }.id(id)
            } else {
                EmptyState(icon: "bell.badge", title: engine.config.topics.isEmpty ? "No topics yet" : "Select a topic",
                           caption: "Add a topic with +. Use the same topic name as in the ntfy app on your phone.")
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
            // A rule left with no topics would apply to every topic: switch it off instead.
            for i in rules.indices where rules[i].topicIds.contains(id) {
                rules[i].topicIds.removeAll { $0 == id }
                if rules[i].topicIds.isEmpty { rules[i].enabled = false }
            }
        }
        selection = engine.config.topics.first?.id
    }

    /// The Default band's plan, plus markers — e.g. "Popup 10 s · by priority · 1 rule".
    private func planSummary(_ t: TopicConfig) -> String {
        let b = t.band(3)
        let popup = t.popup.card.map { cardName($0, engine) } ?? (b.timeoutSec == 0 ? "Popup, stays" : "Popup \(durationLabel(b.timeoutSec))")
        var s = switch b.show {
        case .nothing: "Nothing"
        case .notification: "Notification"
        case .popup: popup
        case .both: t.popup.card == nil ? "Notification + popup" : popup + " + notification"
        }
        if t.bandsDiffer { s += " · by priority" }
        let n = rulesTouching(t.id, engine).count
        if n > 0 { s += " · \(n) rule\(n == 1 ? "" : "s")" }
        return s
    }
}

extension TopicConfig {
    fileprivate var bandsDiffer: Bool { alerts.values.contains { $0 != band(3) } }
}

/// "Stays", "10 s", "2 min".
private func durationLabel(_ sec: Int) -> String {
    sec == 0 ? "Stays" : sec >= 60 && sec % 60 == 0 ? "\(sec / 60) min" : "\(sec) s"
}

/// A plugin card's name: its plugin's ("Alert Card"), else the provider's; the id when unavailable.
@MainActor
private func cardName(_ card: PluginCard, _ engine: Engine) -> String {
    guard let d = engine.dispatcher.rules.registry.descriptors[card.providerId] else { return card.providerId }
    return d.packageId.map(engine.pluginName) ?? d.name
}

@MainActor
private func rulesTouching(_ topicId: UUID, _ engine: Engine) -> [Rule] {
    engine.rules.rules.filter { $0.topicIds.isEmpty || $0.topicIds.contains(topicId) }
}

struct TopicEditor: View {
    let model: AppModel
    let engine: Engine
    @State var draft: TopicConfig
    let isNew: Bool
    var onRemove: (() -> Void)? = nil
    let onDone: (UUID?) -> Void
    @State private var error: String?
    @State private var status: String?
    @State private var commandOn = false
    @State private var sameForAll = false

    private static let timeouts = [0, 5, 10, 15, 20, 30, 60, 120, 300]
    private static let sounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi",
                                 "Submarine", "Tink"]

    var body: some View {
        EditorPane {
            Form {
                Section {
                    TextField("Label", text: $draft.label, prompt: Text("Shown in menus and popups"))
                    Picker("Server", selection: $draft.serverId) {
                        ForEach(engine.config.servers) { s in
                            Text(ServerConfig.validatedURL(s.url)?.host() ?? s.url).tag(s.id)
                        }
                    }
                    LabeledContent("Topic") {
                        HStack {
                            TextField("Topic", text: $draft.topic, prompt: Text("e.g. ntfybar-k3Xq9Lw2…")).labelsHidden()
                                .font(.system(.body, design: .monospaced)).multilineTextAlignment(.trailing)
                            Button("Random") { draft.topic = TopicConfig.randomName() }
                        }
                    }
                    Toggle("Enabled", isOn: $draft.enabled)
                } header: {
                    Text("Subscription")
                } footer: {
                    FormFooter("Anyone who knows a topic name on a public server can read and send to it. Pick a long random one — and keep it out of screenshots.")
                }

                Section {
                    Toggle("Same for every priority", isOn: Binding(get: { sameForAll }, set: { on in
                        sameForAll = on
                        if on { setBand(3, draft.band(3)) }  // copies the Default row to all five
                    }))
                    ForEach(sameForAll ? [3] : TopicConfig.priorities, id: \.self) { p in bandRow(p) }
                } header: {
                    Text("When a message arrives")
                } footer: {
                    FormFooter("Priority is set by the sender (1 min … 5 urgent). A popup stays until dismissed when Close after is Stays. Sounds are macOS system sounds; a notification without a sound here keeps the system notification sound.")
                }

                if draft.popsUpSomewhere {
                    Section {
                        Picker("Style", selection: cardSelection) {
                            Text("NtfyBar popup").tag("")
                            if let id = draft.popup.card?.providerId, !cardChoices.contains(where: { $0.id == id }) {
                                Text("\(id) (plugin unavailable)").tag(id)
                            }
                            ForEach(cardChoices, id: \.id) { c in Text(c.label).tag(c.id) }
                        }
                        if let card = draft.popup.card {
                            if let d = engine.dispatcher.rules.registry.descriptors[card.providerId] {
                                ForEach(d.params, id: \.key) { spec in ParamField(spec: spec, params: cardParams, engine: engine, inForm: true) }
                            } else {
                                Text("Plugin unavailable — its settings are kept.").foregroundStyle(.secondary)
                            }
                        }
                        // A card's own level/position parameters replace these, so they are not shown twice.
                        let cardKeys = Set(engine.dispatcher.rules.registry.descriptors[draft.popup.card?.providerId ?? ""]?.params.map(\.key) ?? [])
                        if !cardKeys.contains("level") {
                            Picker("Show over", selection: $draft.popup.level) {
                                Text("Normal windows").tag(PopupSettings.Level.floating)
                                Text("Full-screen apps too").tag(PopupSettings.Level.overFullScreen)
                            }
                        }
                        if !cardKeys.contains("position") {
                            Picker("Position", selection: $draft.popup.position) {
                                Text("Top center").tag(PopupSettings.Position.topCenter)
                                Text("Top right").tag(PopupSettings.Position.topRight)
                            }
                        }
                        if draft.popup.card == nil {
                            Toggle("Copy button", isOn: $draft.popup.showCopy)
                            Toggle("Open button (click URL)", isOn: $draft.popup.showOpen)
                        }
                    } header: {
                        Text("Popup")
                    } footer: {
                        FormFooter(draft.popup.card.map {
                            "From the \(cardName($0, engine)) plugin. Its parameters decide timing; sounds come from the table above."
                        } ?? "Timing and sound are set per priority above. The popup carries the message's own buttons, plus Copy and Open.")
                    }
                }

                Section {
                    Toggle("Copy the message to the clipboard", isOn: $draft.copyToClipboard)
                    Toggle("Download attachments to ~/Downloads/NtfyBar", isOn: $draft.downloadAttachments)
                    Toggle("Copy the downloaded attachment to the clipboard", isOn: $draft.copyAttachment)
                        .disabled(!draft.downloadAttachments)
                    Toggle("Run a command", isOn: $commandOn)
                    if commandOn {
                        LabeledContent("Command") {
                            TextField("Command", text: commandBinding, prompt: Text("say \"$NTFY_TITLE\""), axis: .vertical).labelsHidden()
                                .font(.system(.body, design: .monospaced)).lineLimit(1...4).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Stepper("Time limit \(draft.command?.timeoutSec ?? 30) s", value: Binding(
                            get: { draft.command?.timeoutSec ?? 30 }, set: { draft.command?.timeoutSec = $0 }), in: 1...600)
                        Toggle("Notify me when it fails", isOn: Binding(
                            get: { draft.command?.notifyOnFailure ?? true }, set: { draft.command?.notifyOnFailure = $0 }))
                    }
                    Toggle("Also run all this for messages missed while away", isOn: $draft.processMissed)
                } header: {
                    Text("Also")
                } footer: {
                    FormFooter(commandOn
                        ? "Runs with /bin/zsh in your home folder. The message arrives in $NTFY_MESSAGE, $NTFY_TITLE, $NTFY_PRIORITY, $NTFY_TAGS, $NTFY_CLICK, $NTFY_ID, $NTFY_TIME, $NTFY_JSON and on stdin — never pasted into the command itself. Quote them (\"$NTFY_TITLE\") and don't hand them to eval or osascript -e."
                        : "These run for every priority, in addition to what you see above.")
                }

                let rules = isNew ? [] : rulesTouching(draft.id, engine)
                if !rules.isEmpty {
                    Section {
                        ForEach(rules) { rule in
                            HStack {
                                Text(rule.name)
                                Pill(rule.skipTopicDefaults ? "Instead" : "Also", tint: rule.skipTopicDefaults ? .orange : nil)
                                if !rule.enabled { Pill("Off") }
                                Spacer()
                            }
                        }
                    } header: {
                        Text("Rules that also apply")
                    } footer: {
                        FormFooter("Rules are exceptions: when a message matches, they add to this plan — or, marked Instead, replace it for that message. Edit them in Rules.")
                    }
                }

                Section("History") {
                    Stepper("Keep the last \(draft.retention.count) messages", value: $draft.retention.count, in: 10...10_000, step: 50)
                    Stepper("…for at most \(draft.retention.days) days", value: $draft.retention.days, in: 1...365)
                }
            }
            .formStyle(.grouped)
        } leading: {
            if let onRemove { Button("Remove Topic…", role: .destructive, action: onRemove) }
            Button("Send Test Message", action: sendTest).disabled(isNew)
                .help("Publishes to this topic. NtfyBar ignores its own messages, so it shows on your other devices, not here.")
            if let status { Text(status).foregroundStyle(.secondary).lineLimit(1) }
        } trailing: {
            if let error { Text(error).foregroundStyle(.red).lineLimit(1) }
            Button("Save", action: save).keyboardShortcut(.defaultAction)
        }
        .onAppear {
            commandOn = draft.command != nil
            sameForAll = !draft.bandsDiffer
        }
        .onChange(of: commandOn) { _, on in
            if on && draft.command == nil { draft.command = CommandSettings(command: "") }
            if !on { draft.command = nil }
        }
    }

    private var commandBinding: Binding<String> {
        Binding(get: { draft.command?.command ?? "" }, set: { draft.command?.command = $0 })
    }

    /// One plan row: what you see, when a popup closes, which sound. Under "Same for every priority" it is
    /// the Default band, written to all five.
    private func bandRow(_ p: Int) -> some View {
        let band = Binding(get: { draft.band(p) }, set: { setBand(p, $0) })
        let word = sameForAll ? "Any priority" : "\(PopupContent.priorityInfo(p).word) · \(p)"
        let timeouts = Self.timeouts.contains(band.wrappedValue.timeoutSec) ? Self.timeouts : Self.timeouts + [band.wrappedValue.timeoutSec]
        let sound = band.wrappedValue.sound
        return LabeledContent(word) {
            HStack(spacing: 8) {
                Picker("Show", selection: Binding(get: { band.wrappedValue.show }, set: { show in
                    var b = band.wrappedValue
                    // Switching to a popup gives the familiar 1.3 defaults: urgent stays, Basso / Glass for urgent / high.
                    if !b.showsPopup, show == .popup || show == .both, b.sound == nil {
                        b.sound = ["5": "Basso", "4": "Glass"][String(p)]
                        b.timeoutSec = p == 5 ? 0 : 20
                    }
                    b.show = show
                    band.wrappedValue = b
                })) {
                    Text("Nothing").tag(AlertBand.Show.nothing)
                    Text("Notification").tag(AlertBand.Show.notification)
                    Text("Popup").tag(AlertBand.Show.popup)
                    Text("Notification + popup").tag(AlertBand.Show.both)
                }
                .labelsHidden().frame(width: 190, alignment: .trailing)
                Picker("Close after", selection: band.timeoutSec) {
                    ForEach(timeouts, id: \.self) { Text(durationLabel($0)).tag($0) }
                }
                .labelsHidden().frame(width: 110, alignment: .trailing)
                .disabled(!band.wrappedValue.showsPopup || draft.popup.card != nil)  // a card decides its own timing
                Picker("Sound", selection: band.sound) {
                    Text("None").tag(String?.none)
                    if let sound, !Self.sounds.contains(sound) { Text(sound).tag(String?.some(sound)) }
                    ForEach(Self.sounds, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden().frame(width: 120, alignment: .trailing)
                .disabled(band.wrappedValue.show == .nothing)
            }
        }
        .help("Priority as the sender set it (ntfy header Priority: 1–5).")
    }

    private func setBand(_ p: Int, _ band: AlertBand) {
        for k in sameForAll ? TopicConfig.priorities : [p] { draft.alerts[String(k)] = band }
    }

    /// Plugin cards on offer: actions of active plugins that declare a popup.
    private var cardChoices: [(id: String, label: String)] {
        engine.pluginPackages.filter { $0.state == .active }.flatMap { pkg -> [(id: String, label: String)] in
            guard let m = pkg.manifest, m.popup != nil else { return [] }
            return m.providers.filter { $0.kind == "action" }.map { (id: $0.id, label: "\(m.name) · \($0.name)") }
        }
    }

    private var cardSelection: Binding<String> {
        Binding(get: { draft.popup.card?.providerId ?? "" },
                set: { id in
                    guard id != draft.popup.card?.providerId ?? "" else { return }
                    draft.popup.card = id.isEmpty ? nil : PluginCard(providerId: id)
                })
    }

    private var cardParams: Binding<Params> {
        Binding(get: { draft.popup.card?.params ?? [:] }, set: { draft.popup.card?.params = $0 })
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
        for (k, b) in draft.alerts {
            draft.alerts[k]?.timeoutSec = max(0, b.timeoutSec)
            if b.sound?.isEmpty == true { draft.alerts[k]?.sound = nil }
        }
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
