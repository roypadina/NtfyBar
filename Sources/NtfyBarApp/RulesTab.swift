import NtfyBarCore
import SwiftUI

struct RulesTab: View {
    let engine: Engine
    @State private var selection: UUID?
    @State private var draft: Rule?

    private var rules: [Rule] { engine.rules.rules }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(rules) { r in
                        HStack {
                            Toggle("", isOn: Binding(get: { r.enabled }, set: { on in
                                try? engine.updateRules { rs in
                                    if let i = rs.firstIndex(where: { $0.id == r.id }) { rs[i].enabled = on }
                                }
                            }))
                            .labelsHidden().toggleStyle(.checkbox)
                            Text(r.name)
                        }
                        .tag(r.id)
                    }
                }
                HStack {
                    Button { draft = Rule(name: "New rule"); selection = nil } label: { Image(systemName: "plus") }
                    Button { remove() } label: { Image(systemName: "minus") }.disabled(selection == nil)
                    Button { move(-1) } label: { Image(systemName: "arrow.up") }.disabled(selection == nil)
                    Button { move(1) } label: { Image(systemName: "arrow.down") }.disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(8)
            }
            .frame(width: 210)
            Divider()
            if let draft {
                RuleEditor(engine: engine, draft: draft) { saved in
                    self.draft = nil
                    selection = saved
                }
                .id("new")
            } else if let id = selection, let rule = rules.first(where: { $0.id == id }) {
                RuleEditor(engine: engine, draft: rule) { _ in }.id(id)
            } else {
                VStack(spacing: 8) {
                    Text("Rules run on every message that matches, top to bottom.").font(.headline)
                    Text("Add one with +, or hand-edit Settings › General › Edit Rules File….").foregroundStyle(.secondary)
                }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = rules.first?.id } }
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
    let onDone: (UUID?) -> Void
    @State private var status: String?

    var body: some View {
        Form {
            Section("Rule") {
                TextField("Name", text: $draft.name)
                LabeledContent("Topics") {
                    VStack(alignment: .leading) {
                        Toggle("Any topic", isOn: Binding(get: { draft.topicIds.isEmpty }, set: { if $0 { draft.topicIds = [] } }))
                        ForEach(engine.config.topics) { t in
                            Toggle(t.displayLabel, isOn: Binding(
                                get: { draft.topicIds.contains(t.id) },
                                set: { on in
                                    if on { draft.topicIds.append(t.id) } else { draft.topicIds.removeAll { $0 == t.id } }
                                }))
                        }
                    }
                }
                Picker("Run when", selection: $draft.matchMode) {
                    Text("all conditions match").tag(Rule.MatchMode.all)
                    Text("any condition matches").tag(Rule.MatchMode.any)
                }
            }
            StepList(title: "Conditions", kind: .condition, steps: $draft.conditions, engine: engine)
            StepList(title: "Actions", kind: .action, steps: $draft.actions, engine: engine)
            Section {
                Toggle("Skip the topic's own notification/popup/copy/command", isOn: $draft.skipTopicDefaults)
                HStack {
                    if let status { Text(status).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Save", action: save).keyboardShortcut(.defaultAction)
                }
            } footer: {
                Text("A rule with no conditions never runs.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

struct StepList: View {
    let title: String
    let kind: ProviderKind
    @Binding var steps: [RuleStep]
    let engine: Engine

    var body: some View {
        let catalog = engine.dispatcher.rules.registry.catalog(kind)
        Section(title) {
            ForEach($steps) { $step in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("", selection: $step.providerId) {
                            if !catalog.contains(where: { $0.id == step.providerId }) {
                                Text("\(step.providerId) (plugin unavailable)").tag(step.providerId)
                            }
                            ForEach(catalog) { d in
                                Text(d.packageId.map { "\(engine.pluginName($0)) › \(d.name)" } ?? d.name).tag(d.id)
                            }
                        }
                        .labelsHidden()
                        Button(role: .destructive) { steps.removeAll { $0.id == step.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    if let d = catalog.first(where: { $0.id == step.providerId }) {
                        Text(d.description).font(.caption).foregroundStyle(.secondary)
                        ForEach(d.params, id: \.key) { spec in ParamField(spec: spec, params: $step.params, engine: engine) }
                    }
                }
                .padding(.vertical, 2)
            }
            Button("Add \(kind == .condition ? "Condition" : "Action")") {
                steps.append(RuleStep(catalog.first?.id ?? ""))
            }
        }
    }
}

struct ParamField: View {
    let spec: ParamSpec
    @Binding var params: Params
    let engine: Engine

    var body: some View {
        switch spec.kind {
        case .bool:
            Toggle(spec.label, isOn: Binding(get: { params.bool(spec.key) ?? false }, set: { params[spec.key] = .bool($0) }))
        case .topic:
            Picker(spec.label, selection: Binding(get: { params.string(spec.key) ?? "" }, set: { params[spec.key] = .string($0) })) {
                Text("Choose…").tag("")
                ForEach(engine.config.topics) { t in Text(t.displayLabel).tag(t.id.uuidString) }
            }
        case .choice:
            Picker(spec.label, selection: Binding(get: { params.string(spec.key) ?? spec.choices?.first ?? "" },
                                                  set: { params[spec.key] = .string($0) })) {
                ForEach(spec.choices ?? [], id: \.self) { Text($0).tag($0) }
            }
        case .number:
            TextField(spec.label, text: Binding(
                get: { params.string(spec.key) ?? "" },
                set: { params[spec.key] = Double($0).map(JSONValue.number) ?? ($0.isEmpty ? nil : .string($0)) }),
                prompt: spec.placeholder.map { Text($0) })
        case .text:
            TextField(spec.label, text: Binding(get: { params.string(spec.key) ?? "" }, set: { params[spec.key] = .string($0) }),
                      prompt: spec.placeholder.map { Text($0) })
        }
    }
}
