import NtfyBarCore
import SwiftUI

struct NtfyBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Never @State/@StateObject here: SwiftUI may build throwaway copies of App (MeetAlert v1.5.2).
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, engine: model.engine)
        } label: {
            MenuBarLabel(engine: model.engine)
        }

        Settings {
            SettingsView(model: model, engine: model.engine)
        }
    }

    static let koFiURL = URL(string: "https://ko-fi.com/roypadina")!
    static let repoURL = URL(string: "https://github.com/roypadina/NtfyBar")!

    /// Template image bundled by Scripts/package_app.sh; `swift run` has no bundle resources, so it falls back to an SF Symbol.
    static let menuBarIcon: NSImage = {
        let image = NSImage(named: "menubar")
            ?? NSImage(systemSymbolName: "bell", accessibilityDescription: nil)
            ?? NSImage()
        image.isTemplate = true
        image.accessibilityDescription = "NtfyBar"
        return image
    }()
}

struct MenuBarLabel: View {
    let engine: Engine

    var body: some View {
        Image(nsImage: NtfyBarApp.menuBarIcon)
        if engine.unreadCount > 0 {
            Text(engine.unreadCount > 99 ? "99+" : "\(engine.unreadCount)")
        }
    }
}

struct MenuContent: View {
    let model: AppModel
    let engine: Engine

    var body: some View {
        Text(StatusSummary.line(config: engine.config, states: engine.streamStates, now: Date()))

        if !engine.recent.isEmpty {
            Menu("Recent") {
                ForEach(engine.recent) { m in
                    Button(model.recentTitle(m)) { model.showRecent(m) }
                }
            }
        }
        Button("Mark All Read") { engine.markAllRead() }
            .disabled(engine.unreadCount == 0)

        Menu("Pause Notifications") {
            if engine.config.isPaused(at: Date()) {
                Button("Resume") { model.pause(until: nil) }
                Divider()
            }
            Button("For 15 Minutes") { model.pause(until: Date().addingTimeInterval(15 * 60)) }
            Button("For 1 Hour") { model.pause(until: Date().addingTimeInterval(3600)) }
            Button("Until Resumed") { model.pause(until: .distantFuture) }
        }
        Button("History…") { HistoryWindow.show(model: model) }

        Divider()

        OpenSettingsButton()

        Divider()

        Button("About NtfyBar") { AboutWindow.show() }
        Button("Support on Ko-fi ☕") { NSWorkspace.shared.open(NtfyBarApp.koFiURL) }

        Divider()

        Button("Quit NtfyBar") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
