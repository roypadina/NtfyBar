import AppKit
import NtfyBarCore
import SwiftUI

/// One dynamic colour from a light/dark pair — same mechanism the system uses for semantic colours,
/// so every Color below flips with the appearance automatically (no @Environment plumbing).
private func dyn(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
}

/// Popup look (MeetAlert palette): one signal hue per accent, ink base over material.
/// Values only — no layout, no behaviour. All colour pairs ≥ 4.9:1.
enum Theme {
    /// Panel base tint over .regularMaterial. Navy-ink, not neutral black.
    static let ink = dyn(light: NSColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 0.45),
                         dark: NSColor(red: 0.05, green: 0.07, blue: 0.13, alpha: 0.55))

    static let info = dyn(light: NSColor(red: 0.00, green: 0.48, blue: 0.60, alpha: 1),     // #007A99  4.9:1 on white
                          dark: NSColor(red: 0.24, green: 0.88, blue: 1.00, alpha: 1))      // #3DE1FF 12.4:1 on ink
    static let warning = dyn(light: NSColor(red: 0.60, green: 0.36, blue: 0.00, alpha: 1),  // #9A5B00  5.9:1 on white
                             dark: NSColor(red: 1.00, green: 0.70, blue: 0.14, alpha: 1))   // #FFB224 10.1:1 on ink
    static let critical = dyn(light: NSColor(red: 0.77, green: 0.12, blue: 0.09, alpha: 1), // #C41E17  6.1:1 on white
                              dark: NSColor(red: 1.00, green: 0.35, blue: 0.31, alpha: 1))  // #FF5A4E  5.5:1 on ink
    static let success = dyn(light: NSColor(red: 0.10, green: 0.45, blue: 0.20, alpha: 1),  // #1A7333  5.9:1 on white
                             dark: NSColor(red: 0.35, green: 0.85, blue: 0.48, alpha: 1))   // #59D97A 10.0:1 on ink
    /// Ink text on the bright dark-mode fills, white on the deep light-mode fills.
    static let onSignal = dyn(light: .white, dark: NSColor(red: 0.05, green: 0.07, blue: 0.13, alpha: 1))

    static let panelRadius: CGFloat = 20  // continuous
    static let rimWidth: CGFloat = 4      // left signal bar
    static let strokeWidth: CGFloat = 1   // hairline edge (2 under Increase Contrast)

    static let title = Font.system(size: 16, weight: .semibold)
    static let body = Font.system(size: 13)
    static let meta = Font.system(size: 13)
    static let state = Font.system(size: 12, weight: .semibold, design: .rounded)
    static let button = Font.system(size: 13, weight: .semibold)

    static func color(_ accent: PopupContent.Accent) -> Color {
        switch accent {
        case .info: info
        case .success: success
        case .warning: warning
        case .critical: critical
        }
    }
}
