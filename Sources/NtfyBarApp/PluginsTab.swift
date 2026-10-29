import NtfyBarCore
import SwiftUI

/// What the consent sheet shows, for a package already on disk (bundled / local) or one that was
/// downloaded and verified but not yet written (marketplace install).
struct ConsentRequest: Identifiable {
    enum Kind { case package(PluginManager.Package), install(PreparedInstall) }

    let kind: Kind
    var manifest: PluginManifest {
        switch kind {
        case let .package(p): p.manifest!
        case let .install(i): i.manifest
        }
    }
    var id: String { manifest.id }
    var verified: Bool {
        switch kind {
        case let .package(p): p.verified
        case let .install(i): i.marketplaceURL == PluginSettings.officialMarketplace
        }
    }
}

struct PluginsTab: View {
    let model: AppModel
    let engine: Engine
    @State private var section = "installed"
    @State private var consent: ConsentRequest?
    @State private var uninstalling: PluginManager.Package?
    @State private var available: [(source: String, entry: MarketplaceEntry)] = []
    @State private var busy = false
    @State private var status: String?
    @State private var newMarketplace = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $section) {
                Text("Installed").tag("installed")
                Text("Available").tag("available")
                Text("Sources").tag("sources")
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.top, 12)
            if section == "installed" {
                FormFooter("Cards appear in a topic's Popup › Style; conditions and actions appear in a rule's pickers — after you enable the plugin.")
                    .padding(.horizontal, 20).padding(.top, 8)
            }
            switch section {
            case "available": availableView
            case "sources": sourcesView
            default: installedView
            }
        }
        .sheet(item: $consent) { req in
            ConsentSheet(request: req, onAllow: { allow(req) }, onCancel: { consent = nil })
        }
        .confirmationDialog(uninstalling.map { "Uninstall \($0.manifest?.name ?? $0.id)?" } ?? "Uninstall?",
                            isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } }),
                            titleVisibility: .visible, presenting: uninstalling) { pkg in
            Button("Uninstall", role: .destructive) { try? engine.uninstallPlugin(pkg.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You can install it again from Available.")
        }
    }

    // MARK: installed

    @ViewBuilder private var installedView: some View {
        if engine.pluginPackages.isEmpty {
            EmptyState(icon: "puzzlepiece.extension", title: "No plugins yet", caption: "Browse Available, or add a folder under Sources.")
        } else {
            installedList
        }
    }

    private var installedList: some View {
        Form {
            ForEach(engine.pluginPackages) { pkg in
                Section {
                    packageHeader(pkg)
                    switch pkg.state {
                    case .needsConsent:
                        HStack {
                            Text(pkg.manifest.map { engine.config.plugins.grants[$0.id] == nil ? "Not enabled yet." : "Asks for new permissions." } ?? "")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Review and Enable…") { consent = ConsentRequest(kind: .package(pkg)) }
                        }
                    case .disabled:
                        Toggle("Enabled", isOn: Binding(get: { false }, set: { _ in try? engine.setPluginEnabled(pkg.id, true) }))
                    case .active:
                        Toggle("Enabled", isOn: Binding(get: { true }, set: { _ in try? engine.setPluginEnabled(pkg.id, false) }))
                        if let m = pkg.manifest, !m.grantedPermissions.isEmpty {
                            ForEach(m.grantedPermissions, id: \.self) { p in
                                Toggle(isOn: Binding(get: { engine.isGranted(pkg.id, p) },
                                                     set: { try? engine.setPermission(p, pluginId: pkg.id, granted: $0) })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.consent)
                                        if let reason = m.permissionReasons?[p.rawValue] {
                                            Text("Plugin says: \(reason)").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    case .invalid:
                        EmptyView()
                    }
                    ForEach(pkg.errors, id: \.self) { e in
                        Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(pkg.state == .invalid ? .red : .orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// MaccyPlus PackageGroupView header: name, version, source pill, unverified pill, Uninstall.
    private func packageHeader(_ pkg: PluginManager.Package) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(pkg.manifest?.name ?? pkg.id).fontWeight(.semibold)
                if let m = pkg.manifest { Text(m.version).foregroundStyle(.secondary) }
                Pill(sourceName(pkg.source), tint: .accentColor)
                if !pkg.verified { Pill("Unverified", tint: .orange, icon: "exclamationmark.shield") }
                Spacer()
                if pkg.source == .installed {
                    Button(role: .destructive) { uninstalling = pkg } label: {
                        Label("Uninstall", systemImage: "trash").font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let m = pkg.manifest {
                Text(m.description).font(.caption).foregroundStyle(.secondary)
                if !m.providers.isEmpty {
                    Text("Adds: " + m.providers.map { p in
                        "\(p.name) — " + (p.kind == "condition" ? "rule condition" : m.popup != nil ? "popup card for a topic or a rule" : "rule action")
                    }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if let author = m.author?.name { Text("by \(author)").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func sourceName(_ s: PluginManager.Source) -> String {
        switch s {
        case .bundled: "Bundled"
        case .installed: "Marketplace"
        case .local: "Local folder"
        }
    }

    // MARK: available

    private var availableView: some View {
        Form {
            Section {
                HStack {
                    Button(busy ? "Loading…" : "Refresh") { refresh() }.disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                    if let status { Text(status).foregroundStyle(.secondary).lineLimit(2) }
                }
            } footer: {
                FormFooter("NtfyBar only contacts marketplaces when you press Refresh or Install. Every file is checked against its published SHA-256 before anything is written.")
            }
            ForEach(available, id: \.entry.id) { item in
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .top, spacing: 6) {
                            Text(item.entry.name).fontWeight(.medium)
                            Text(item.entry.version).foregroundStyle(.secondary)
                            if item.source != PluginSettings.officialMarketplace {
                                Pill("Unverified", tint: .orange, icon: "exclamationmark.shield")
                            }
                            Spacer()
                            if let conflict = engine.installConflict(id: item.entry.id, marketplaceURL: item.source) {
                                Text(conflict).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing).frame(maxWidth: 200)
                            } else if installLabel(item.entry) == "Installed" {
                                Pill("Installed")
                            } else {
                                Button(installLabel(item.entry)) { install(item.entry, from: item.source) }.disabled(busy)
                            }
                        }
                        Text(item.entry.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(item.entry.permissions.isEmpty ? "No extra permissions" : "Asks for: " + item.entry.permissions.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("From " + (item.source == PluginSettings.officialMarketplace ? "the official marketplace"
                                                                                           : URL(string: item.source)?.host() ?? item.source))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func installLabel(_ e: MarketplaceEntry) -> String {
        guard let pkg = engine.pluginPackages.first(where: { $0.id == e.id && $0.source == .installed }), let m = pkg.manifest else {
            return "Install…"
        }
        return PluginManifest.compareVersions(e.version, m.version) == .orderedDescending ? "Update…" : "Installed"
    }

    private func refresh() {
        busy = true
        status = nil
        let urls = engine.config.plugins.marketplaces
        Task { @MainActor in
            var found: [(String, MarketplaceEntry)] = []
            var failures: [String] = []
            for text in urls {
                guard let url = URL(string: text) else { failures.append("Couldn't load \(text): not a valid URL"); continue }
                do {
                    let index = try await Marketplace.fetchIndex(url, session: EffectPerformer.actionSession)
                    found += index.plugins.map { (text, $0) }
                } catch {
                    let reason = (error as? MarketplaceError).map { String(describing: $0) } ?? error.localizedDescription
                    failures.append("Couldn't load \(url.host() ?? text): \(reason)")
                }
            }
            available = found
            status = failures.first.map { $0 + (failures.count > 1 ? " (\(failures.count - 1) more failed)" : "") }
                ?? "\(found.count) plugin\(found.count == 1 ? "" : "s") available."
            busy = false
        }
    }

    private func install(_ entry: MarketplaceEntry, from source: String) {
        busy = true
        status = "Downloading and verifying \(entry.name)…"
        let version = engine.plugins.appVersion
        Task { @MainActor in
            do {
                let prepared = try await Marketplace.prepare(entry, marketplaceURL: source, session: EffectPerformer.actionSession,
                                                             appVersion: version)
                status = nil
                consent = ConsentRequest(kind: .install(prepared))
            } catch {
                status = String(describing: error)
            }
            busy = false
        }
    }

    private func allow(_ req: ConsentRequest) {
        consent = nil
        do {
            switch req.kind {
            case let .package(pkg): try engine.consent(to: pkg)
            case let .install(prepared): try engine.install(prepared)
            }
            status = nil
            section = "installed"
        } catch {
            status = error.localizedDescription
        }
    }

    // MARK: sources

    private var sourcesView: some View {
        Form {
            Section {
                ForEach(engine.config.plugins.localFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        removeButton { updateFolders { $0.removeAll { $0 == path } } }
                    }
                }
                HStack {
                    Button("Add Folder…", action: addFolder)
                    Button("Reload Plugins") { engine.reloadPlugins() }
                }
            } header: {
                Text("Local folders")
            } footer: {
                FormFooter("For developing your own plugins: a folder with plugin.json, or a folder of such folders. Local plugins are marked as unverified.")
            }
            Section("Marketplaces") {
                ForEach(engine.config.plugins.marketplaces, id: \.self) { url in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(.secondary)
                        Text(url == PluginSettings.officialMarketplace ? "Official (NtfyBar-Plugins)" : url).lineLimit(1).truncationMode(.middle)
                        if url == PluginSettings.officialMarketplace { Pill("Official", tint: .accentColor) }
                        Spacer()
                        removeButton { try? engine.update { $0.plugins.marketplaces.removeAll { $0 == url } } }
                    }
                }
                HStack {
                    TextField("https://…/marketplace.json", text: $newMarketplace)
                    Button("Add") {
                        guard let url = URL(string: newMarketplace), url.scheme == "https", url.host() != nil else { return }
                        try? engine.update { c in if !c.plugins.marketplaces.contains(url.absoluteString) { c.plugins.marketplaces.append(url.absoluteString) } }
                        newMarketplace = ""
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) { Image(systemName: "trash") }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove").accessibilityLabel("Remove")
    }

    private func updateFolders(_ change: (inout [String]) -> Void) {
        try? engine.update { change(&$0.plugins.localFolders) }
        engine.reloadPlugins()
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateFolders { if !$0.contains(url.path) { $0.append(url.path) } }
    }
}

struct ConsentSheet: View {
    let request: ConsentRequest
    let onAllow: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let m = request.manifest
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: request.verified ? "puzzlepiece.extension.fill" : "exclamationmark.shield.fill").font(.title2)
                    .foregroundStyle(request.verified ? Color.accentColor : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable “\(m.name)” \(m.version)?").font(.headline)
                    if let author = m.author?.name { Text("by \(author)").foregroundStyle(.secondary) }
                }
            }
            if !request.verified {
                Label("Unverified source. Only continue if you trust whoever made this plugin.", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            }
            Text("It will be able to:").font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                Label(Permission.implicitConsent, systemImage: "envelope.open")
                ForEach(m.grantedPermissions, id: \.self) { p in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.consent)
                            if let reason = m.permissionReasons?[p.rawValue] {
                                Text("Why: \(reason)").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: icon(p))
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("Plugins can never run commands, use the network, read your clipboard or files, change your settings, or subscribe to topics.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Allow and Enable", action: onAllow).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func icon(_ p: Permission) -> String {
        switch p {
        case .historyRead: "clock.arrow.circlepath"
        case .topicsRead: "list.bullet"
        case .publish: "paperplane"
        case .clipboardWrite: "doc.on.clipboard"
        case .openURL: "safari"
        case .storage: "externaldrive"
        case .ui: "rectangle.on.rectangle"
        }
    }
}
