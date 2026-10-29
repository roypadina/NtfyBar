import NtfyBarCore
import SwiftUI
import UserNotifications

struct SettingsView: View {
    let model: AppModel
    let engine: Engine
    var initialTab: String?  // only the Renderer sets it
    @AppStorage("settingsTab") private var tab = "general"  // reopen on the last tab (SET-3)

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab(model: model, engine: engine, notifier: model.notifier)
                .tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            TopicsTab(model: model, engine: engine)
                .tabItem { Label("Topics", systemImage: "bell.badge") }.tag("topics")
            ServersTab(engine: engine)
                .tabItem { Label("Servers", systemImage: "server.rack") }.tag("servers")
            RulesTab(engine: engine)
                .tabItem { Label("Rules", systemImage: "bolt") }.tag("rules")
            PluginsTab(model: model, engine: engine)
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }.tag("plugins")
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 640, idealHeight: 720)
        .onAppear { if let initialTab { tab = initialTab } }
    }
}

/// Immediate-save binding into the config (toggles, pickers).
@MainActor
func configBinding<T>(_ engine: Engine, _ path: WritableKeyPath<Config, T>) -> Binding<T> {
    Binding(get: { engine.config[keyPath: path] },
            set: { value in try? engine.update { $0[keyPath: path] = value } })
}

struct GeneralTab: View {
    let model: AppModel
    let engine: Engine
    @ObservedObject var notifier: Notifier
    @State private var start = ""
    @State private var end = ""

    var body: some View {
        Form {
            Section("Startup") {
                LaunchAtLoginToggle()
            }
            Section("Notifications") {
                LabeledContent("macOS notifications") {
                    HStack {
                        permissionStatus
                        if notifier.isAvailable {
                            Button("Open System Settings…") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                            }
                        }
                    }
                }
                LabeledContent("Pause notifications") {
                    if let until = engine.config.pausedUntil, until > Date() {
                        HStack {
                            Text(until == .distantFuture ? "Until resumed" : "Until \(until.formatted(date: .omitted, time: .shortened))")
                                .foregroundStyle(.secondary)
                            Button("Resume") { model.pause(until: nil) }
                        }
                    } else {
                        Menu("Pause…") {
                            Button("For 15 Minutes") { model.pause(until: Date().addingTimeInterval(15 * 60)) }
                            Button("For 1 Hour") { model.pause(until: Date().addingTimeInterval(3600)) }
                            Button("Until Resumed") { model.pause(until: .distantFuture) }
                        }
                        .fixedSize()
                    }
                }
            }
            Section {
                Toggle("Cap the priority of messages NtfyBar sends", isOn: configBinding(engine, \.quietHours.enabled))
                LabeledContent("Hours") {
                    HStack(spacing: 6) {
                        TextField("Start", text: $start, prompt: Text("20:00")).labelsHidden().textFieldStyle(.roundedBorder)
                            .frame(width: 64).multilineTextAlignment(.center)
                        Text("to").foregroundStyle(.secondary)
                        TextField("End", text: $end, prompt: Text("09:00")).labelsHidden().textFieldStyle(.roundedBorder)
                            .frame(width: 64).multilineTextAlignment(.center)
                    }
                }
                Picker("Highest priority during quiet hours", selection: configBinding(engine, \.quietHours.maxPriority)) {
                    ForEach(1...5, id: \.self) { p in Text(PopupContent.priorityInfo(p).word).tag(p) }
                }
            } header: {
                Text("Quiet hours for sending")
            } footer: {
                FormFooter("Only for messages NtfyBar sends — rules, plugins, Publish and test messages — so nobody's phone rings at night. Incoming messages are not affected: use Pause, or give the topic a quieter plan. Times are 24-hour HH:MM.",
                           warning: !validTimes)
            }
            Section("Files") {
                HStack {
                    Button("Edit Config File…") { NSWorkspace.shared.open(engine.store.configURL) }
                    Button("Edit Rules File…") { model.openRulesFile() }
                    Button("Reload Files") { engine.reloadFromDisk() }
                    Button("Show Data Folder") { NSWorkspace.shared.activateFileViewerSelecting([engine.store.configURL]) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            start = engine.config.quietHours.start
            end = engine.config.quietHours.end
            notifier.refreshAuthorization()
        }
        .onChange(of: start) { _, _ in saveQuietHours() }
        .onChange(of: end) { _, _ in saveQuietHours() }
    }

    /// Full HH:MM only, so typing "20:05" never saves the half-typed "20:0".
    private var validTimes: Bool { [start, end].allSatisfy { $0.count == 5 && QuietHours.isValidTime($0) } }

    /// Saves as soon as both times are valid (no Save button); skips the no-op write from onAppear.
    private func saveQuietHours() {
        guard validTimes, start != engine.config.quietHours.start || end != engine.config.quietHours.end else { return }
        try? engine.update {
            $0.quietHours.start = start
            $0.quietHours.end = end
        }
    }

    @ViewBuilder private var permissionStatus: some View {
        if !notifier.isAvailable {
            Text("Unavailable (not running as an app bundle)").foregroundStyle(.secondary)
        } else {
            switch notifier.authorization {
            case .authorized, .provisional: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .denied: Label("Off", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            default: Text("Not decided yet").foregroundStyle(.secondary)
            }
        }
    }
}

struct ServersTab: View {
    let engine: Engine
    @State private var selection: UUID?
    @State private var draft: ServerConfig?

    var body: some View {
        HStack(spacing: 0) {
            SidebarPane(selection: $selection, onAdd: { draft = ServerConfig(url: "https://"); selection = nil }, onRemove: remove,
                        removeDisabled: selection == nil || engine.config.topics.contains { $0.serverId == selection },
                        removeHelp: "A server still used by a topic can't be removed") {
                ForEach(engine.config.servers) { s in
                    SidebarRow(title: ServerConfig.validatedURL(s.url)?.host() ?? "Invalid URL", subtitle: authKind(s.auth)).tag(s.id)
                }
            } extraButtons: { EmptyView() }
            Divider()
            if let draft {
                ServerEditor(engine: engine, draft: draft, isNew: true) { saved in
                    self.draft = nil
                    selection = saved
                }
                .id("new")
            } else if let id = selection, let server = engine.config.server(id) {
                ServerEditor(engine: engine, draft: server, isNew: false, onRemove: { remove() }) { _ in }.id(id)
            } else {
                EmptyState(icon: "server.rack", title: "Select a server", caption: "Add your own ntfy server with +. ntfy.sh is built in.")
            }
        }
        .onAppear { if selection == nil { selection = engine.config.servers.first?.id } }
    }

    private func authKind(_ auth: ServerAuth) -> String {
        switch auth {
        case .none: "No sign-in"
        case .basic: "Username and password"
        case .token: "Access token"
        }
    }

    private func remove() {
        guard let id = selection else { return }
        try? engine.update { $0.servers.removeAll { $0.id == id } }
        selection = engine.config.servers.first?.id
    }
}

struct ServerEditor: View {
    let engine: Engine
    @State var draft: ServerConfig
    let isNew: Bool
    var onRemove: (() -> Void)? = nil
    let onDone: (UUID?) -> Void
    @State private var authType = "none"
    @State private var confirmRemove = false
    @State private var user = ""
    @State private var pass = ""
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        EditorPane {
            Form {
                Section {
                    TextField("URL", text: $draft.url, prompt: Text("https://ntfy.sh"))
                    Picker("Sign-in", selection: $authType) {
                        Text("None").tag("none")
                        Text("Username and password").tag("basic")
                        Text("Access token").tag("token")
                    }
                    if authType == "basic" {
                        TextField("Username", text: $user)
                        SecureField("Password", text: $pass)
                    } else if authType == "token" {
                        SecureField("Token", text: $token, prompt: Text("tk_…"))
                    }
                    if authType != "none", draft.url.lowercased().hasPrefix("http://") {
                        Label("Plain http sends these credentials unencrypted.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    FormFooter("Credentials are stored in NtfyBar's config file (readable only by you). Redirects are never followed — enter the server's final URL.")
                }
            }
            .formStyle(.grouped)
        } leading: {
            if onRemove != nil {
                let inUse = engine.config.topics.contains { $0.serverId == draft.id }
                Button("Remove Server…", role: .destructive) { confirmRemove = true }
                    .disabled(inUse)
                    .help(inUse ? "Remove or move its topics first" : "")
            }
        } trailing: {
            if let error { Text(error).foregroundStyle(.red).lineLimit(1) }
            Button("Save", action: save).keyboardShortcut(.defaultAction)
        }
        .alert("Remove this server?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { onRemove?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its address and sign-in details are deleted from NtfyBar.")
        }
        .onAppear {
            switch draft.auth {
            case .none: authType = "none"
            case let .basic(u, p): authType = "basic"; user = u; pass = p
            case let .token(t): authType = "token"; token = t
            }
        }
    }

    private func save() {
        guard let url = ServerConfig.validatedURL(draft.url) else {
            error = "Enter an http(s) URL without user name, query or #fragment."
            return
        }
        draft.url = url.absoluteString
        draft.auth = authType == "basic" ? .basic(user: user, pass: pass) : authType == "token" ? .token(token) : .none
        let server = draft
        try? engine.update { c in
            if let i = c.servers.firstIndex(where: { $0.id == server.id }) { c.servers[i] = server } else { c.servers.append(server) }
        }
        error = nil
        onDone(server.id)
    }
}

struct AboutTab: View {
    private let info = Bundle.main.infoDictionary ?? [:]

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            Text("NtfyBar").font(.title2.bold())
            Text("Version \(info["CFBundleShortVersionString"] as? String ?? "dev") (\(info["CFBundleVersion"] as? String ?? "dev"))")
                .foregroundStyle(.secondary)
            HStack {
                Button("About NtfyBar…") { AboutWindow.show() }
                Button("Welcome Guide…") { WelcomeWindow.show() }
                Button("Support on Ko-fi ☕") { NSWorkspace.shared.open(NtfyBarApp.koFiURL) }.buttonStyle(.borderedProminent)
            }
            .controlSize(.large).padding(.top, 4)
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
