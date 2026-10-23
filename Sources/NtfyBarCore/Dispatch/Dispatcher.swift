import Foundation

/// Flood guard: more than `threshold` live messages on one topic within `window` seconds starts a
/// burst; while it lasts, popups collapse into one summary popup. The burst ends after `window`
/// seconds without a message on that topic.
public struct FloodGuard: Sendable {
    public var threshold = 5
    public var window: TimeInterval = 10

    private struct TopicState: Sendable {
        var recent: [Date] = []
        var last: Date?
        var flooding = false
        var suppressed = 0
    }

    private var topics: [UUID: TopicState] = [:]

    public init(threshold: Int = 5, window: TimeInterval = 10) {
        self.threshold = threshold
        self.window = window
    }

    /// nil = show normally; n = collapsed, n messages folded into the summary so far.
    public mutating func record(_ topicId: UUID, at now: Date) -> Int? {
        var st = topics[topicId] ?? TopicState()
        if let last = st.last, now.timeIntervalSince(last) >= window { st = TopicState() }
        st.recent = st.recent.filter { now.timeIntervalSince($0) < window } + [now]
        st.last = now
        if st.flooding || st.recent.count > threshold {
            st.flooding = true
            st.suppressed += 1
        }
        topics[topicId] = st
        return st.flooding ? st.suppressed : nil
    }
}

/// Decides the effects of one stored message. Pure apart from its own counters: no AppKit, no I/O.
@MainActor
public final class Dispatcher {
    public var rules: RuleEngine
    private var flood: FloodGuard
    private var catchUpCounts: [UUID: Int] = [:]

    public init(rules: RuleEngine = RuleEngine(), flood: FloodGuard = FloodGuard()) {
        self.rules = rules
        self.flood = flood
    }

    public func handle(_ m: Message, config: Config, now: Date) -> [Effect] {
        guard let topic = config.topic(m.topicId) else { return [] }
        if m.isCatchUp && !topic.processMissed {
            catchUpCounts[m.topicId, default: 0] += 1
            return []
        }
        let outcome = rules.evaluate(m, topic: topic, config: config)
        var effects = outcome.skipTopicDefaults ? [] : topicDefaults(m, topic: topic)
        effects += outcome.effects

        // Flood guard (live or processMissed messages only — plain catch-up returned above): during a
        // burst, banners, popups and sounds collapse into one notice + one counting popup.
        if effects.contains(where: Self.isAlert), let collapsed = flood.record(m.topicId, at: now) {
            let hadPopup = effects.contains(where: Self.isPopup)
            let hadNotify = effects.contains { if case .notify = $0 { true } else { false } }
            effects.removeAll { Self.isAlert($0) || Self.isSound($0) }
            if collapsed == 1, hadNotify { effects.append(.floodNotification(topicId: m.topicId, label: topic.displayLabel)) }
            if hadPopup { effects.append(.summaryPopup(topicId: m.topicId, label: topic.displayLabel, count: collapsed)) }
        }
        return config.isPaused(at: now) ? effects.filter { !$0.interrupts } : effects
    }

    /// One "N messages while away" notification per topic, for catch-up messages collected since
    /// the last flush. The engine calls this shortly after the replay burst ends.
    public func flushCatchUp(config: Config, now: Date) -> [Effect] {
        defer { catchUpCounts.removeAll() }
        guard !config.isPaused(at: now) else { return [] }
        return catchUpCounts.sorted { $0.key.uuidString < $1.key.uuidString }.compactMap { topicId, count in
            guard let topic = config.topic(topicId), topic.notify else { return nil }
            return .summaryNotification(topicId: topicId, label: topic.displayLabel, count: count)
        }
    }

    public var hasPendingCatchUp: Bool { !catchUpCounts.isEmpty }

    private func topicDefaults(_ m: Message, topic: TopicConfig) -> [Effect] {
        var effects: [Effect] = []
        if topic.notify { effects.append(.notify(m, label: topic.displayLabel)) }
        if topic.popup.enabled {
            effects.append(.popup(PopupRequest(message: m, label: topic.displayLabel, settings: topic.popup)))
        }
        if let sound = topic.soundOverride ?? (topic.popup.enabled ? topic.popup.sound(forPriority: m.priority) : nil),
           !sound.isEmpty {
            effects.append(.playSound(sound))
        }
        if topic.copyToClipboard { effects.append(.copy(m.body)) }
        if let command = topic.command, !command.command.trimmingCharacters(in: .whitespaces).isEmpty {
            effects.append(.runCommand(command, m, label: topic.displayLabel))
        }
        return effects
    }

    private static func isPopup(_ e: Effect) -> Bool {
        if case .popup = e { return true }
        return false
    }

    private static func isAlert(_ e: Effect) -> Bool {
        switch e {
        case .popup, .notify: true
        default: false
        }
    }

    private static func isSound(_ e: Effect) -> Bool {
        if case .playSound = e { return true }
        return false
    }
}
