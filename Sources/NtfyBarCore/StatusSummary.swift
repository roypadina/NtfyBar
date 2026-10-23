import Foundation

/// The one-line connection state shown at the top of the menu. Never names a topic.
public enum StatusSummary {
    public static func line(config: Config, states: [UUID: NtfyStream.State], now: Date) -> String {
        let active = config.topics.filter { $0.enabled && TopicConfig.isValidTopicName($0.topic) }
        let base: String
        if active.isEmpty {
            base = config.topics.isEmpty ? "No topics yet — add one in Settings" : "No active topics"
        } else if states.values.contains(where: { if case .authFailed = $0 { true } else { false } }) {
            base = "Sign-in failed — check Settings › Servers"
        } else if states.values.contains(where: { if case .reconnecting = $0 { true } else { false } }) {
            base = "Reconnecting…"
        } else if !states.isEmpty, states.values.allSatisfy({ $0 == .connected }) {
            base = "Connected · \(active.count) topic\(active.count == 1 ? "" : "s")"
        } else {
            base = "Connecting…"
        }
        guard let until = config.pausedUntil, until > now else { return base }
        let when = until == .distantFuture ? "until resumed" : "until " + until.formatted(date: .omitted, time: .shortened)
        return "Paused \(when) · " + base
    }
}
