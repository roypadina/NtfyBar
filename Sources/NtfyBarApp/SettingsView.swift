import NtfyBarCore
import SwiftUI
import UserNotifications

struct SettingsView: View {
    let model: AppModel
    let engine: Engine
    var initialTab = "general"
    @State private var tab = ""

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab(model: model, engine: engine, notifier: model.notifier)
                .tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            TopicsTab(model: model, engine: engine)
                .tabItem { Label("Topics", systemImage: "bell.badge") }.tag("topics")
            ServersTab(engine: engine)
                .tabItem { Label("Servers", systemImage: "server.rack") }.tag("servers")
            RulesTab(engine: engine)
                .tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }.tag("rules")
            PluginsTab(model: model, engine: engine)
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }.tag("plugins")
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .frame(width: 720, height: 560)
        .onAppear { if tab.isEmpty { tab = initialTab } }
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
                Toggle("Launch NtfyBar at login", isOn: Binding(
                    get: { engine.config.launchAtLogin },
                    set: { on in
                        try? LoginItemManager().setEnabled(on)
                        try? engine.update { $0.launchAtLogin = on }
                    }))
            }
            Section("Notifications") {
                LabeledContent("macOS notifications") {
                    HStack {
                        Text(permissionText).foregroundStyle(.secondary)
                        Button("Open System Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                }
                LabeledContent("Pause") {
                    HStack {
                        if let until = engine.config.pausedUntil, until > Date() {
                            Text(until == .distantFuture ? "Paused until resumed" : "Paused until \(until.formatted(date: .omitted, time: .shortened))")
                                .foregroundStyle(.secondary)
                            Button("Resume") { model.pause(until: nil) }
                        } else {
                            Button("Pause 1 Hour") { model.pause(until: Date().addingTimeInterval(3600)) }
                            Button("Pause Until Resumed") { model.pause(until: .distantFuture) }
                        }
                    }
                }
            }
            Section {
                Toggle("Cap the priority of messages NtfyBar sends", isOn: configBinding(engine, \.quietHours.enabled))
                HStack {
                    TextField("From", text: $start).frame(width: 80).onSubmit(saveQuietHours)
                    Text("to")
                    TextField("Until", text: $end).frame(width: 80).onSubmit(saveQuietHours)
                    Button("Save", action: saveQuietHours).disabled(!validTimes)
                }
                Picker("Highest priority during quiet hours", selection: configBinding(engine, \.quietHours.maxPriority)) {
                    ForEach(1...5, id: \.self) { p in Text(PopupContent.priorityInfo(p).word).tag(p) }
                }
            } header: {
                Text("Quiet hours")
            } footer: {
                Text("Applies to everything NtfyBar publishes — rules, plugins and test messages — so nobody's phone rings at night. Times are 24-hour HH:MM.")
                    .font(.caption).foregroundStyle(.secondary)
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
    }

    private var validTimes: Bool { QuietHours.isValidTime(start) && QuietHours.isValidTime(end) }

    private func saveQuietHours() {
        guard validTimes else { return }
        try? engine.update {
            $0.quietHours.start = start
            $0.quietHours.end = end
        }
    }

    private var permissionText: String {
        guard notifier.isAvailable else { return "Unavailable (not running as an app bundle)" }
        switch notifier.authorization {
        case .authorized, .provisional: return "Allowed"
        case .denied: return "Off — turn on in System Settings"
        default: return "Not decided yet"
        }
    }
}

struct ServersTab: View {
    let engine: Engine
    @State private var selection: UUID?
    @State private var draft: ServerConfig?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(engine.config.servers) { s in
                        Text(ServerConfig.validatedURL(s.url)?.host() ?? "Invalid URL").tag(s.id)
                    }
                }
                HStack {
                    Button { draft = ServerConfig(url: "https://"); selection = nil } label: { Image(systemName: "plus") }
                    Button { remove() } label: { Image(systemName: "minus") }
                        .disabled(selection == nil || engine.config.topics.contains { $0.serverId == selection })
                        .help("A server still used by a topic can't be removed")
                    Spacer()
                }
                .buttonStyle(.borderless).padding(8)
            }
            .frame(width: 210)
            Divider()
            if let draft {
                ServerEditor(engine: engine, draft: draft, isNew: true) { saved in
                    self.draft = nil
                    selection = saved
                }
                .id("new")
            } else if let id = selection, let server = engine.config.server(id) {
                ServerEditor(engine: engine, draft: server, isNew: false) { _ in }.id(id)
            } else {
                Text("Select a server, or add your own ntfy server with +.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = engine.config.servers.first?.id } }
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
    let onDone: (UUID?) -> Void
    @State private var authType = "none"
    @State private var user = ""
    @State private var pass = ""
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section("Server") {
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
            }
            Section {
                HStack {
                    if let error { Text(error).foregroundStyle(.red) }
                    Spacer()
                    Button("Save", action: save).keyboardShortcut(.defaultAction)
                }
            } footer: {
                Text("Credentials are stored in NtfyBar's config file (readable only by you). Redirects are never followed — enter the server's final URL.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text("NtfyBar").font(.headline)
                        Text("Made by Roy Padina · MIT").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("About NtfyBar…") { AboutWindow.show() }
                    Button("Support on Ko-fi ☕") { NSWorkspace.shared.open(NtfyBarApp.koFiURL) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
