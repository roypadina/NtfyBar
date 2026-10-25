import SwiftUI

/// Master list for the Topics, Servers and Rules tabs (MaccyPlus ActionsSettingsPane sidebar):
/// list, divider, borderless +/− footer, 220 pt wide.
struct SidebarPane<Rows: View, Extra: View>: View {
    @Binding var selection: UUID?
    var onAdd: () -> Void
    var onRemove: () -> Void
    var removeDisabled = false
    var removeHelp = ""
    @ViewBuilder var rows: () -> Rows
    @ViewBuilder var extraButtons: () -> Extra

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) { rows() }
            Divider()
            HStack(spacing: 4) {
                Button(action: onAdd) { Image(systemName: "plus") }
                Button(action: onRemove) { Image(systemName: "minus") }.disabled(removeDisabled).help(removeHelp)
                extraButtons()
                Spacer()
            }
            .buttonStyle(.borderless).padding(6)
        }
        .frame(width: 220)
    }
}

/// Sidebar row: enabled dot, title, optional caption.
struct SidebarRow: View {
    var enabled = true
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: enabled ? "circle.fill" : "circle").font(.system(size: 7))
                .foregroundStyle(enabled ? Color.accentColor : .secondary)
                .accessibilityLabel(enabled ? "Enabled" : "Disabled")
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }
}

/// Editor with a pinned footer bar, so Save stays visible however long the form is.
struct EditorPane<Content: View, Leading: View, Trailing: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var leading: () -> Leading     // status / test button
    @ViewBuilder var trailing: () -> Trailing   // error text + Save

    var body: some View {
        VStack(spacing: 0) {
            content().frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) { leading(); Spacer(minLength: 0); trailing() }
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

/// Capsule label (MaccyPlus / Agents Monitor badges). No tint = neutral grey.
struct Pill: View {
    let text: String
    var tint: Color?
    var icon: String?

    init(_ text: String, tint: Color? = nil, icon: String? = nil) {
        self.text = text
        self.tint = tint
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text)
        }
        .font(.caption2).fontWeight(tint == nil ? .regular : .semibold)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background((tint ?? Color.secondary).opacity(tint == nil ? 0.15 : 0.18), in: Capsule())
        .foregroundStyle(tint ?? Color.secondary)
    }
}

/// Centred icon + title + caption for an empty list or detail pane.
struct EmptyState: View {
    let icon: String
    let title: String
    var caption: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).foregroundStyle(.secondary)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
            }
        }
        .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Grouped-form section footer: small, grey, flush-left. SwiftPM links against the macOS 14 SDK,
/// where the form's default footer is trailing body text, so the newer-SDK look is pinned here.
struct FormFooter: View {
    let text: String
    var warning = false

    init(_ text: String, warning: Bool = false) {
        self.text = text
        self.warning = warning
    }

    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(warning ? .orange : .secondary)
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}
