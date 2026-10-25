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
                    SidebarRow(enabled: t.enabled, title: t.displayLabel, subtitle: planSummary(t)).tag(t.id).help(planSummary(t))
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

    /// The Default band's plan, plus the important one or markers — e.g. "Popup 10 s · high and up: Popup, stays · 1 rule".
    private func planSummary(_ t: TopicConfig) -> String {
        func plan(_ b: AlertBand) -> String {
            let popup = t.popup.card.map { cardName($0, engine) } ?? (b.timeoutSec == 0 ? "Popup, stays" : "Popup \(durationLabel(b.timeoutSec))")
            return switch b.show {
            case .nothing: "Nothing"
            case .notification: "Notification"
            case .popup: popup
            case .both: t.popup.card == nil ? "Notification + popup" : popup + " + notification"
            }
        }
        var s = switch t.planShape {
        case .same: plan(t.band(3))
        case .important(minPriority: 4): "\(plan(t.band(3))) · high and up: \(plan(t.band(5)))"
        case .important: "\(plan(t.band(3))) · urgent: \(plan(t.band(5)))"
        case .custom: "\(plan(t.band(3))) · by priority"
        }
        let n = rulesTouching(t.id, engine).count
        if n > 0 { s += " · \(n) rule\(n == 1 ? "" : "s")" }
        return s
    }
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
    @State private var mode = TopicConfig.PlanShape.same
    @State private var confirmSimplify = false

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

                if mode == .custom {
                    Section {
                        LabeledContent("Custom per priority") { Button("Use simple settings…") { confirmSimplify = true } }
                        ForEach(TopicConfig.priorities, id: \.self) { p in bandRow(p) }
                    } header: {
                        Text("When a message arrives")
                    } footer: {
                        FormFooter("Each priority has its own row (the sender sets it: ntfy header Priority: 1–5). Use simple settings… replaces the rows with one plan plus one for important messages.")
                    }
                } else {
                    Section {
                        planRows(Binding(get: { draft.band(3) }, set: { setGroup(important: false, $0) }))
                        Toggle("Handle important messages differently", isOn: importantOn)
                    } header: {
                        Text("When a message arrives")
                    } footer: {
                        FormFooter("Sounds are macOS system sounds. A notification with no sound here keeps the system notification sound.")
                    }
                    if importantOn.wrappedValue {
                        Section {
                            Picker("Priority", selection: Binding(get: { threshold }, set: setThreshold)) {
                                Text("High and urgent (4–5)").tag(4)
                                Text("Urgent only (5)").tag(5)
                            }
                            planRows(Binding(get: { draft.band(5) }, set: { setGroup(important: true, $0) }))
                        } header: {
                            Text("Important messages")
                        } footer: {
                            FormFooter("The sender sets the priority (ntfy header Priority: 1–5). For important messages these rows replace the ones above.")
                        }
                    }
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
                            "From the \(cardName($0, engine)) plugin. Its parameters decide timing; sounds come from When a message arrives."
                        } ?? "Timing and sound are set in When a message arrives. The popup carries the message's own buttons, plus Copy and Open.")
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
            mode = draft.planShape
        }
        .onChange(of: commandOn) { _, on in
            if on && draft.command == nil { draft.command = CommandSettings(command: "") }
            if !on { draft.command = nil }
        }
        .alert("Replace the five rows?", isPresented: $confirmSimplify) {
            Button("Replace") { setThreshold(4) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Priorities 3, 2 and 1 will use the Default row; 5 and 4 will use the Urgent row. Nothing is saved until you click Save.")
        }
    }

    private var commandBinding: Binding<String> {
        Binding(get: { draft.command?.command ?? "" }, set: { draft.command?.command = $0 })
    }

    /// The first important priority; 6 while the switch is off, so every band is "base".
    private var threshold: Int { if case let .important(t) = mode { t } else { 6 } }

    private var importantOn: Binding<Bool> {
        Binding(get: { if case .important = mode { true } else { false } }, set: { on in
            if on {
                mode = .important(minPriority: 4)
                // The 1.3 urgent default, as one group: stays, Basso unless the plan already has a sound.
                var b = draft.band(3)
                b.timeoutSec = 0
                b.sound = b.sound ?? "Basso"
                setGroup(important: true, b)
            } else {
                mode = .same
                setGroup(important: false, draft.band(3))
            }
        })
    }

    /// Also "Use simple settings…" (4): the Default row for the bands below, the Urgent row from there up.
    private func setThreshold(_ t: Int) {
        mode = .important(minPriority: t)
        setGroup(important: false, draft.band(3))
        setGroup(important: true, draft.band(5))
    }

    private func setGroup(important: Bool, _ b: AlertBand) {
        for p in 1...5 where (p >= threshold) == important { draft.alerts[String(p)] = b }
    }

    /// Show, Close the popup after, Sound — for the base plan or the important one.
    @ViewBuilder
    private func planRows(_ band: Binding<AlertBand>) -> some View {
        Picker("Show", selection: band.show) { showItems }
        if band.wrappedValue.showsPopup && draft.popup.card == nil {  // a card decides its own timing
            Picker("Close the popup after", selection: band.timeoutSec) { timeoutItems(band.wrappedValue.timeoutSec) }
        }
        Picker("Sound", selection: band.sound) { soundItems(band.wrappedValue.sound) }
    }

    @ViewBuilder
    private var showItems: some View {
        Text("Nothing").tag(AlertBand.Show.nothing)
        Text("A macOS notification").tag(AlertBand.Show.notification)
        Text("NtfyBar's popup").tag(AlertBand.Show.popup)
        Text("Notification and popup").tag(AlertBand.Show.both)
    }

    private func timeoutItems(_ current: Int) -> some View {
        ForEach(Self.timeouts.contains(current) ? Self.timeouts : Self.timeouts + [current], id: \.self) { Text(durationLabel($0)).tag($0) }
    }

    @ViewBuilder
    private func soundItems(_ current: String?) -> some View {
        Text("None").tag(String?.none)
        if let current, !Self.sounds.contains(current) { Text(current).tag(String?.some(current)) }
        ForEach(Self.sounds, id: \.self) { Text($0).tag(String?.some($0)) }
    }

    /// One row of the Custom per priority table: what you see, when a popup closes, which sound.
    private func bandRow(_ p: Int) -> some View {
        let band = Binding(get: { draft.band(p) }, set: { draft.alerts[String(p)] = $0 })
        return LabeledContent("\(PopupContent.priorityInfo(p).word) · \(p)") {
            HStack(spacing: 8) {
                Picker("Show", selection: band.show) { showItems }
                    .labelsHidden().frame(width: 190, alignment: .trailing)
                Picker("Close after", selection: band.timeoutSec) { timeoutItems(band.wrappedValue.timeoutSec) }
                    .labelsHidden().frame(width: 110, alignment: .trailing)
                    .disabled(!band.wrappedValue.showsPopup || draft.popup.card != nil)  // a card decides its own timing
                Picker("Sound", selection: band.sound) { soundItems(band.wrappedValue.sound) }
                    .labelsHidden().frame(width: 120, alignment: .trailing)
            }
        }
        .help("Priority as the sender set it (ntfy header Priority: 1–5).")
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
