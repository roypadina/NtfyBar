import Foundation

/// The one-time 1.3 → 1.4 fold of "priority band" rules into topic plans. Only rules of the strict
/// shape below are absorbed, and only where every (topic, priority) keeps exactly the same effects;
/// everything else stays in rules.json verbatim.
public enum Migration {
    public struct Outcome: Equatable, Sendable {
        public var config: Config
        public var rules: RulesFile
        /// One human line per change ("absorbed rule 'NAS high' into NAS", "NAS: copyToClipboard was never reached; set to false").
        public var notes: [String]
    }

    private static let popupKeys: Set<String> = ["timeoutSec", "level", "position", "buttonLabel", "buttonURL"]

    private typealias Style = (level: PopupSettings.Level, position: PopupSettings.Position)

    /// Pure. `cardProviders` = ids of active plugin action providers whose package declares `popup`.
    /// Expects 1.3 topics (bands expanded by the decoder, no card).
    public static func toV2(config: Config, rules: RulesFile, cardProviders: Set<String>) -> Outcome {
        let topics = Dictionary(config.topics.map { ($0.id, $0) }) { first, _ in first }  // as Config.topic(_:)
        var covered: [UUID: Set<Int>] = [:]
        var bands: [UUID: [Int: AlertBand]] = [:]
        var styles: [UUID: Style] = [:]
        var cards: [UUID: PluginCard] = [:]
        var absorbed: [UUID] = []

        ruleLoop: for r in rules.rules where r.enabled && !r.topicIds.isEmpty && r.skipTopicDefaults {
            // 1. exactly one condition: builtin.priority (same defaults as BuiltinProviders)
            guard r.conditions.count == 1, let cond = r.conditions.first, cond.providerId == "builtin.priority" else { continue }
            let value = cond.params.int("value") ?? 3
            let band: Set<Int> = switch cond.params.string("op") ?? ">=" {
            case "==": Set(1...5).filter { $0 == value }
            case "<=": Set(1...5).filter { $0 <= value }
            default: Set(1...5).filter { $0 >= value }
            }
            guard !band.isEmpty else { continue }

            // 2. actions ⊆ {popup, card, playSound, notify, ignore}; at most one popup-or-card, one sound
            var popupParams: Params?
            var card: PluginCard?
            var sound: String?
            var notify = false
            for a in r.actions {
                switch a.providerId {
                case "builtin.popup":
                    guard popupParams == nil, card == nil, (a.params.string("buttonLabel") ?? "").isEmpty,
                          Set(a.params.keys).isSubset(of: popupKeys) else { continue ruleLoop }
                    popupParams = a.params
                case "builtin.playSound":
                    guard sound == nil, let n = a.params.string("name"), !n.trimmingCharacters(in: .whitespaces).isEmpty else { continue ruleLoop }
                    sound = n
                case "builtin.notify":
                    notify = true
                case "builtin.ignore":
                    break  // the skip flag is already on
                case let id where cardProviders.contains(id):
                    guard card == nil, popupParams == nil else { continue ruleLoop }
                    card = PluginCard(providerId: id, params: a.params)
                default:
                    continue ruleLoop
                }
            }

            // 3. every topic must accept it (a multi-topic rule is absorbed as a whole or not at all)
            var proposed: [UUID: [Int: AlertBand]] = [:]
            var proposedStyle: [UUID: Style] = [:]
            for tid in r.topicIds {
                guard let t = topics[tid], band.isDisjoint(with: covered[tid] ?? []) else { continue ruleLoop }
                // A card and NtfyBar's popup can't share one topic: the card would replace every popup.
                if let pp = popupParams {
                    guard t.popup.card == nil, cards[tid] == nil else { continue ruleLoop }
                    let s: Style = (pp.string("level").flatMap(PopupSettings.Level.init(rawValue:)) ?? t.popup.level,
                                    pp.string("position").flatMap(PopupSettings.Position.init(rawValue:)) ?? t.popup.position)
                    // the topic's own popup (uncovered bands) and earlier rules must use the same look
                    if t.popsUpSomewhere { guard s == (t.popup.level, t.popup.position) else { continue ruleLoop } }
                    if let earlier = styles[tid] { guard s == earlier else { continue ruleLoop } }
                    proposedStyle[tid] = s
                }
                if let c = card {
                    guard t.popup.card == nil, !t.popsUpSomewhere, styles[tid] == nil, cards[tid] == nil || cards[tid] == c else { continue ruleLoop }
                }
                let show: AlertBand.Show = (popupParams != nil || card != nil) ? (notify ? .both : .popup) : (notify ? .notification : .nothing)
                for p in band {
                    var timeout = t.band(p).timeoutSec  // builtin.popup without timeoutSec inherited the topic's (= the expanded band)
                    if let pp = popupParams, let explicit = pp.int("timeoutSec").map({ max(0, $0) }) {
                        guard let resolved = ruleTimeout(explicit, priority: p, topic: t) else { continue ruleLoop }
                        timeout = resolved
                    } else if let explicit = card?.params.int("timeoutSec") {
                        timeout = max(0, explicit)  // display only: a card decides its own timing
                    }
                    proposed[tid, default: [:]][p] = AlertBand(show: show, timeoutSec: timeout, sound: sound)
                }
            }

            // 4. absorb
            for (tid, ps) in proposed {
                bands[tid, default: [:]].merge(ps) { _, new in new }
                covered[tid, default: []].formUnion(ps.keys)
            }
            styles.merge(proposedStyle) { _, new in new }
            if let c = card { for tid in r.topicIds { cards[tid] = c } }
            absorbed.append(r.id)
        }

        // 5. per topic: the old plan must have nothing that can't move into it
        var reverted = Set<UUID>()
        let absorbedIds = Set(absorbed)
        for (tid, set) in covered where !set.isEmpty {
            let t = topics[tid]!
            let alsoOn = t.copyToClipboard || t.downloadAttachments
                || t.command?.command.trimmingCharacters(in: .whitespaces).isEmpty == false
            // per-band copy/download/command is not expressible → keep those rules
            if alsoOn && set != Set(1...5) { reverted.insert(tid); continue }
            // A rule that stays and skips the plan would now also skip the absorbed bands; one that reads
            // the topic's popup (builtin.popup, plugin cards) would see the new style and timeouts.
            let interferes = rules.rules.contains { k in
                k.enabled && !absorbedIds.contains(k.id) && (k.topicIds.isEmpty || k.topicIds.contains(tid))
                    && (k.skipTopicDefaults || k.actions.contains { $0.providerId == "builtin.ignore" || $0.providerId == "builtin.popup" || !$0.providerId.hasPrefix("builtin.") })
            }
            if interferes { reverted.insert(tid) }
        }

        // 6. write plans
        var notes: [String] = []
        var out = config
        for i in out.topics.indices {
            let tid = out.topics[i].id
            guard let set = covered[tid], !set.isEmpty, !reverted.contains(tid) else { continue }
            for (p, b) in bands[tid] ?? [:] { out.topics[i].alerts[String(p)] = b }
            if let s = styles[tid] { out.topics[i].popup.level = s.level; out.topics[i].popup.position = s.position }
            if let c = cards[tid] { out.topics[i].popup.card = c }
            if set == Set(1...5) {
                let label = out.topics[i].displayLabel
                if out.topics[i].copyToClipboard { out.topics[i].copyToClipboard = false; notes.append("\(label): copyToClipboard was never reached; set to false") }
                if out.topics[i].downloadAttachments { out.topics[i].downloadAttachments = false; notes.append("\(label): downloadAttachments was never reached; set to false") }
                if out.topics[i].copyAttachment { out.topics[i].copyAttachment = false; notes.append("\(label): copyAttachment was never reached; set to false") }
                if out.topics[i].command != nil { out.topics[i].command = nil; notes.append("\(label): command was never reached; removed") }
            }
        }

        // 7. rules file: absorbed rules go, or stay narrowed to the reverted topics; all others untouched
        var outRules = rules
        outRules.rules = []
        for r in rules.rules {
            guard absorbedIds.contains(r.id) else { outRules.rules.append(r); continue }
            let remaining = r.topicIds.filter { reverted.contains($0) }
            if remaining.count == r.topicIds.count { outRules.rules.append(r); continue }  // nothing absorbed after all
            let into = r.topicIds.filter { !reverted.contains($0) }.compactMap { topics[$0]?.displayLabel }.joined(separator: ", ")
            notes.append("absorbed rule '\(r.name)' into \(into)")
            if !remaining.isEmpty {
                var kept = r
                kept.topicIds = remaining
                outRules.rules.append(kept)
                notes.append("rule '\(r.name)' kept for \(remaining.count) topic(s)")
            }
        }
        return Outcome(config: out, rules: outRules, notes: notes)
    }

    /// 1.3 applied the topic's "urgent stays" to a rule's popup too, so an explicit rule timeout became 0
    /// at priority 5. The expanded bands tell whether it was on: band 5 is 0 and band 4 isn't. nil = can't tell.
    private static func ruleTimeout(_ explicit: Int, priority: Int, topic t: TopicConfig) -> Int? {
        guard priority == 5, explicit != 0 else { return explicit }
        if t.band(5).timeoutSec != 0 { return explicit }  // urgent-stays was off
        if t.band(4).timeoutSec != 0 { return 0 }         // it was on
        return nil
    }
}
