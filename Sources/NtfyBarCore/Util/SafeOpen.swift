import Foundation

/// The one gate every "open this URL" goes through — notification Open, popup Open/attachment,
/// ntfy `view` buttons, markdown links, rule actions and plugins. Message content is attacker-
/// controlled: `file:`, `shortcuts:`, `x-apple.systempreferences:` and friends must never open.
public enum SafeOpen {
    public static func url(_ text: String?) -> URL? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let url = URL(string: text) else { return nil }
        return isAllowed(url) ? url : nil
    }

    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host ?? "").isEmpty
    }
}
