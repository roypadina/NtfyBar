import NtfyBarCore
import SwiftUI

// shortcut: M1 settings — config file editing only; the tabbed editor arrives in M2b.
struct SettingsView: View {
    let model: AppModel
    let engine: Engine

    var body: some View {
        Form {
            Section("Configuration") {
                HStack {
                    Button("Edit Config File…") { NSWorkspace.shared.open(engine.store.configURL) }
                    Button("Reload") { engine.reloadFromDisk() }
                }
            }
            Section("About") {
                HStack {
                    Button("About NtfyBar…") { AboutWindow.show() }
                    Button("Support on Ko-fi ☕") { NSWorkspace.shared.open(NtfyBarApp.koFiURL) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}
