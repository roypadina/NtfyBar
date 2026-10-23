import NtfyBarCore
import SwiftUI

// shortcut: M2 placeholder — the plugin manager arrives in M3.
struct PluginsTab: View {
    let model: AppModel
    let engine: Engine

    var body: some View {
        Text("Plugins").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
