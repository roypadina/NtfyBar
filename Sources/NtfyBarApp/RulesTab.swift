import NtfyBarCore
import SwiftUI

struct RulesTab: View {
    let engine: Engine
    @State private var selection: UUID?
    @State private var draft: Rule?

    private var rules: [Rule] { engine.rules.rules }

    var body: some View {
        HStack(spacing: 0) {
            SidebarPane(selection: $selection, onAdd: { draft = Rule(name: "New rule"); selection = nil }, onRemove: remove,
                        removeDisabled: selection == nil) {
                ForEach(rules) { r in
                    HStack {
                        Toggle("", isOn: Binding(get: { r.enabled }, set: { on in
                            try? engine.updateRules { rs in
                                if let i = rs.firstIndex(where: { $0.id == r.id }) { rs[i].enabled = on }
                            }
                        }))
                        .labelsHidden().toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name).lineLimit(1)
                            Text(scope(r)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(r.id)
                }
            } extraButtons: {
                Button { move(-1) } label: { Image(systemName: "arrow.up") }.disabled(selection == nil)
                Button { move(1) } label: { Image(systemName: "arrow.down") }.disabled(selection == nil)
            }
            Divider()
            if let draft {
                RuleEditor(engine: engine, draft: draft) { saved in
                    self.draft = nil
                    selection = saved
                }
                .id("new")
            } else if let id = selection, let rule = rules.first(where: { $0.id == id }) {
                RuleEditor(engine: engine, draft: rule, onRemove: { remove() }) { _ in }.id(id)
            } else {
                EmptyState(icon: "bolt.badge.clock", title: rules.isEmpty ? "No rules" : "Select a rule",
                           caption: "Rules are exceptions to a topic's plan: when a message matches, also do something — or do it instead. To change what a topic always does, edit the topic in Topics.")
            }
        }
        .onAppear { if selection == nil { selection = rules.first?.id } }
    }

    /// "Instead · NAS · Monitoring +2": which topics the rule touches, so the top-to-bottom order reads.
    private func scope(_ r: Rule) -> String {
        let labels = r.topicIds.compactMap { engine.config.topic($0)?.displayLabel }
        let topics = r.topicIds.isEmpty ? "Any topic"
            : labels.prefix(2).joined(separator: " · ") + (labels.count > 2 ? " +\(labels.count - 2)" : "")
        return (r.skipTopicDefaults ? "Instead · " : "") + topics
    }

    private func remove() {
        guard let id = selection else { return }
        try? engine.updateRules { $0.removeAll { $0.id == id } }
        selection = rules.first?.id
    }

    private func move(_ delta: Int) {
        guard let id = selection else { return }
        try? engine.updateRules { rs in
            guard let i = rs.firstIndex(where: { $0.id == id }), rs.indices.contains(i + delta) else { return }
            rs.swapAt(i, i + delta)
        }
    }
}

struct RuleEditor: View {
    let engine: Engine
    @State var draft: Rule
    var onRemove: (() -> Void)? = nil
    let onDone: (UUID?) -> Void
    @State private var confirmRemove = false
    @State private var status: String?

    var body: some View {
        EditorPane {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Rule name", text: $draft.name).textFieldStyle(.roundedBorder)
                    GroupBox {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
                            Toggle("Any topic", isOn: Binding(get: { draft.topicIds.isEmpty }, set: { if $0 { draft.topicIds = [] } }))
                                .toggleStyle(.checkbox)
                            ForEach(engine.config.topics) { t in
                                Toggle(t.displayLabel, isOn: Binding(
                                    get: { draft.topicIds.contains(t.id) },
                                    set: { on in
                                        if on { draft.topicIds.append(t.id) } else { draft.topicIds.removeAll { $0 == t.id } }
                                    }))
                                    .toggleStyle(.checkbox)
                            }
                        }
                        .padding(6)
                    } label: {
                        Text("Topics").font(.headline)
                    }
                    StepList(title: "Conditions", kind: .condition, steps: $draft.conditions, engine: engine, matchMode: $draft.matchMode)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Then", selection: $draft.skipTopicDefaults) {
                                Text("Also do the actions below").tag(false)
                                Text("Instead of the topic's plan").tag(true)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                            Text(draft.skipTopicDefaults
                                ? "For matching messages the topic's plan (notification, popup, sound, copy, download, command) is skipped; only the actions below run."
                                : "The topic's plan runs as usual, plus the actions below.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Then").font(.headline)
                    }
                    StepList(title: "Actions", kind: .action, steps: $draft.actions, engine: engine)
                }
                .padding(20)
            }
        } leading: {
            if onRemove != nil { Button("Remove Rule…", role: .destructive) { confirmRemove = true } }
            if let status { Text(status).foregroundStyle(.secondary).lineLimit(1) }
        } trailing: {
            Button("Save", action: save).keyboardShortcut(.defaultAction)
        }
        .alert("Remove this rule?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { onRemove?() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func save() {
        var rule = draft
        // The list's checkbox owns "enabled"; don't overwrite it with this editor's older copy.
        rule.enabled = engine.rules.rules.first { $0.id == rule.id }?.enabled ?? true
        try? engine.updateRules { rs in
            if let i = rs.firstIndex(where: { $0.id == rule.id }) { rs[i] = rule } else { rs.append(rule) }
        }
        status = "Saved"
        onDone(rule.id)
    }
}

/// Conditions or actions card (MaccyPlus conditionsBox / actionsBox). Pass `matchMode` for conditions.
struct StepList: View {
    let title: String
    let kind: ProviderKind
    @Binding var steps: [RuleStep]
    let engine: Engine
    var matchMode: Binding<Rule.MatchMode>?

    var body: some View {
        let catalog = engine.dispatcher.rules.registry.catalog(kind)
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let matchMode {
                    Picker("Match", selection: matchMode) {
                        Text("Match ALL conditions").tag(Rule.MatchMode.all)
                        Text("Match ANY condition").tag(Rule.MatchMode.any)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if steps.isEmpty {
                    Text(kind == .condition ? "No conditions — this rule never runs. To change what a topic always does, edit its plan in Topics."
                                            : "No actions yet.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach($steps) { $step in
                    StepRow(step: $step, catalog: catalog, engine: engine) { steps.removeAll { $0.id == step.id } }
                    if kind == .action && step.id != steps.last?.id { Divider() }
                }
                Button { steps.append(RuleStep(catalog.first?.id ?? "")) } label: {
                    Label(kind == .condition ? "Add condition" : "Add action", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title).font(.headline)
        }
    }
}

/// Provider picker + ⓘ description popover + trash, params below (MaccyPlus ActionRow: NtfyBar
/// steps have several labelled params, which don't fit beside the picker).
struct StepRow: View {
    @Binding var step: RuleStep
    let catalog: [ProviderDescriptor]
    let engine: Engine
    let onDelete: () -> Void
    @State private var showHelp = false

    var body: some View {
        let descriptor = catalog.first { $0.id == step.providerId }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $step.providerId) {
                    if descriptor == nil {
                        Text("\(step.providerId) (plugin unavailable)").tag(step.providerId)
                    }
                    ForEach(catalog) { d in
                        Text(d.packageId.map { "\(engine.pluginName($0)) › \(d.name)" } ?? d.name).tag(d.id)
                    }
                }
                .labelsHidden().frame(width: 240)
                .help(descriptor?.description ?? "")
                if let d = descriptor {
                    Button { showHelp.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .accessibilityLabel("Description")
                        .popover(isPresented: $showHelp) { Text(d.description).padding().frame(maxWidth: 320) }
                }
                Spacer(minLength: 0)
                Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            if let d = descriptor {
                ForEach(d.params, id: \.key) { ParamField(spec: $0, params: $step.params, engine: engine) }
            }
        }
    }
}

struct ParamField: View {
    let spec: ParamSpec
    @Binding var params: Params
    let engine: Engine
    /// In a grouped Form (a topic's plugin card) rows already show their label and align the value right.
    var inForm = false

    var body: some View {
        switch spec.kind {
        case .bool:
            Toggle(spec.label, isOn: Binding(get: { params.bool(spec.key) ?? false }, set: { params[spec.key] = .bool($0) }))
        case .topic:
            Picker(spec.label, selection: Binding(get: { params.string(spec.key) ?? "" }, set: { params[spec.key] = .string($0) })) {
                Text("Choose…").tag("")
                ForEach(engine.config.topics) { t in Text(t.displayLabel).tag(t.id.uuidString) }
            }
            .fixedSize(horizontal: !inForm, vertical: !inForm)
        case .choice:
            Picker(spec.label, selection: Binding(get: { params.string(spec.key) ?? spec.choices?.first ?? "" },
                                                  set: { params[spec.key] = .string($0) })) {
                ForEach(spec.choices ?? [], id: \.self) { Text($0).tag($0) }
            }
            .fixedSize(horizontal: !inForm, vertical: !inForm)
        case .number:
            textRow(Binding(get: { params.string(spec.key) ?? "" },
                            set: { params[spec.key] = Double($0).map(JSONValue.number) ?? ($0.isEmpty ? nil : .string($0)) }))
        case .text:
            textRow(Binding(get: { params.string(spec.key) ?? "" }, set: { params[spec.key] = .string($0) }))
        }
    }

    @ViewBuilder private func textRow(_ text: Binding<String>) -> some View {
        if inForm {
            TextField(spec.label, text: text, prompt: spec.placeholder.map { Text($0) })
        } else {
            // Outside a Form a TextField hides its title, so the label is shown explicitly like the pickers'.
            LabeledContent(spec.label) {
                TextField(spec.label, text: text, prompt: spec.placeholder.map { Text($0) }).labelsHidden().textFieldStyle(.roundedBorder)
            }
        }
    }
}
