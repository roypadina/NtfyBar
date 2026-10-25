import Foundation
import Testing
@testable import NtfyBarCore

/// 1.3 → 1.4: priority-band rules fold into topic plans with identical runtime effects.
@Suite("Migration")
@MainActor
struct MigrationTests {
    static let card = "com.ntfybar.alert-card.show"
    let server = Config().servers[0]

    final class LegacyPopups { var byTopic: [UUID: PopupSettings] = [:] }
    /// Each fixture topic's 1.3 popup settings, for the 1.3 `builtin.popup` below.
    let legacyPopups = LegacyPopups()

    /// A 1.3 topic: the decoder's expansion of its toggles.
    func legacy(_ label: String, notify: Bool = true, popup: Bool = false, timeout: Int = 20, sticky: Bool = true) -> TopicConfig {
        var t = TopicConfig(serverId: server.id, topic: "ntfybar-\(label.lowercased().filter(\.isLetter))", label: label)
        var p = PopupSettings()
        p.enabled = popup
        p.timeoutSec = timeout
        p.stickyForUrgent = sticky
        t.alerts = AlertBand.expand(notify: notify, popup: p, soundOverride: nil)
        legacyPopups.byTopic[t.id] = p
        return t
    }

    /// The 1.3 runtime for rules: `builtin.popup` as at 706290c — the topic's own popup settings, "urgent
    /// stays" included, plus the rule's overrides — and the card stub (1.3 passed the topic's level/position).
    func registry13() -> ProviderRegistry {
        let r = cardRegistry(Self.card)
        let popups = legacyPopups
        r.register(r.descriptors["builtin.popup"]!) { ctx, p in
            var s = popups.byTopic[ctx.topic.id] ?? PopupSettings()
            s.enabled = true
            if let t = p.int("timeoutSec") { s.timeoutSec = max(0, t) }
            if let l = p.string("level").flatMap(PopupSettings.Level.init(rawValue:)) { s.level = l }
            if let pos = p.string("position").flatMap(PopupSettings.Position.init(rawValue:)) { s.position = pos }
            var buttons: [PopupButton] = []
            if let label = p.string("buttonLabel"), !label.isEmpty, let tpl = p.string("buttonURL") {
                let url = Template.render(tpl, message: ctx.message, topicLabel: ctx.label, urlEncode: true)
                guard SafeOpen.url(url) != nil else { throw ProviderError.badParams("buttonURL must be an http(s) URL") }
                buttons.append(PopupButton(id: "rule-button", label: label, openURL: url))
            }
            return ActionOutput([.popup(PopupRequest(message: ctx.message, label: ctx.label, settings: s, extraButtons: buttons))])
        }
        return r
    }

    func prio(_ op: String, _ v: Int) -> [RuleStep] { [RuleStep("builtin.priority", ["op": .string(op), "value": .number(Double(v))])] }
    func popup(_ timeout: Int?, position: String = "topRight") -> RuleStep {
        var p: Params = ["level": .string("floating"), "position": .string(position)]
        if let timeout { p["timeoutSec"] = .number(Double(timeout)) }
        return RuleStep("builtin.popup", p)
    }
    let basso = RuleStep("builtin.playSound", ["name": .string("Basso")])

    func config(_ topics: [TopicConfig]) -> Config {
        var c = Config()
        c.servers = [server]
        c.topics = topics
        c.schemaVersion = 1
        return c
    }

    // MARK: equivalence

    func describe(_ e: Effect) -> String {
        switch e {
        case let .popup(req):
            let c = PopupContent.forMessage(req)
            return "popup t=\(c.timeoutSec) \(c.level) \(c.position) \(c.buttons.map(\.id)) \(req.extraButtons.map(\.id))"
        case let .pluginPopup(req):
            let c = req.content
            return "card \(req.pluginId) t=\(c.timeoutSec) \(c.level) \(c.position)"
        default:
            return String(describing: e)
        }
    }

    /// Every topic × priority (and the clipboard tag): the 1.3 rules on the 1.3 topics (bands = the decoder's
    /// expansion of the 1.3 toggles) give the same effects as the migrated files on 1.4.
    func expectEquivalent(_ before: (Config, RulesFile), _ after: Migration.Outcome) {
        for t in before.0.topics {
            for p in 1...5 {
                for tags in [nil, ["maccyplus"]] as [[String]?] {
                    let m = makeMessage(topicId: t.id, id: "m\(p)", title: "Disk", priority: p, tags: tags)
                    let now = Date(timeIntervalSince1970: 1_700_000_000)
                    let old = Dispatcher(rules: RuleEngine(rules: before.1.rules, registry: registry13())).handle(m, config: before.0, now: now)
                    let new = Dispatcher(rules: RuleEngine(rules: after.rules.rules, registry: cardRegistry(Self.card))).handle(m, config: after.config, now: now)
                    #expect(old.map(describe).sorted() == new.map(describe).sorted(), "\(t.label) priority \(p) tags \(tags ?? [])")
                }
            }
        }
    }

    // MARK: Roy's shapes (synthetic names and ids)

    struct Fixture {
        var config: Config
        var rules: RulesFile
        var ids: [String: UUID]
    }

    func roysShape() -> Fixture {
        var topics = [legacy("Personal", notify: false, popup: true, timeout: 0), legacy("Work", notify: false, popup: true),
                      legacy("NAS"), legacy("Monitoring"), legacy("Public"), legacy("GitHub"), legacy("Clipboard"),
                      legacy("Meetings"), legacy("Agents")]
        topics[0].processMissed = true
        topics[6].copyToClipboard = true
        topics[6].downloadAttachments = true
        topics[6].copyAttachment = true
        let old = (1...10).map { legacy("Old\(String(UnicodeScalar(UInt8(64 + $0))))") }
        topics += old
        var ids: [String: UUID] = [:]
        for t in topics { ids[t.label] = t.id }
        let cardParams: Params = ["timeoutSec": .number(0), "position": .string("topCenter"), "level": .string("overFullScreen"),
                                  "snoozeMin": .number(0), "countToday": .bool(true)]
        let rules = [
            Rule(name: "ignore my own", topicIds: [ids["Clipboard"]!], conditions: [RuleStep("builtin.hasTag", ["tag": .string("maccyplus")])],
                 actions: [RuleStep("builtin.ignore")], skipTopicDefaults: true),
            Rule(name: "NAS high", topicIds: [ids["NAS"]!], conditions: prio(">=", 4), actions: [popup(0), basso], skipTopicDefaults: true),
            Rule(name: "NAS low", topicIds: [ids["NAS"]!], conditions: prio("<=", 3), actions: [popup(10)], skipTopicDefaults: true),
            Rule(name: "Public card", topicIds: [ids["Public"]!], conditions: prio(">=", 1),
                 actions: [RuleStep(Self.card, cardParams), basso], skipTopicDefaults: true),
            Rule(name: "Mon high", topicIds: [ids["Monitoring"]!], conditions: prio(">=", 4), actions: [popup(0), basso], skipTopicDefaults: true),
            Rule(name: "Mon low", topicIds: [ids["Monitoring"]!], conditions: prio("<=", 3), actions: [popup(10)], skipTopicDefaults: true),
            Rule(name: "GitHub", topicIds: [ids["GitHub"]!], conditions: prio(">=", 1), actions: [popup(10)], skipTopicDefaults: true),
            Rule(name: "Old", topicIds: old.map(\.id), conditions: prio(">=", 1), actions: [popup(0), basso], skipTopicDefaults: true),
        ]
        return Fixture(config: config(topics), rules: RulesFile(rules: rules), ids: ids)
    }

    @Test func roysShapeBecomesPlans() {
        let f = roysShape()
        let out = Migration.toV2(config: f.config, rules: f.rules, cardProviders: [Self.card])
        #expect(out.rules.rules.map(\.name) == ["ignore my own"])
        #expect(out.notes.count == 7 && out.notes.allSatisfy { $0.hasPrefix("absorbed rule") })
        let t = { (label: String) in out.config.topic(f.ids[label]!)! }

        for label in ["NAS", "Monitoring"] {
            #expect(t(label).popup.position == .topRight && t(label).popup.level == .floating)
            for p in [5, 4] { #expect(t(label).band(p) == AlertBand(show: .popup, timeoutSec: 0, sound: "Basso")) }
            for p in 1...3 { #expect(t(label).band(p) == AlertBand(show: .popup, timeoutSec: 10)) }
        }
        let pub = t("Public")
        #expect(pub.popup.card?.providerId == Self.card && pub.popup.card?.params["countToday"] == .bool(true))
        for p in 1...5 { #expect(pub.band(p) == AlertBand(show: .popup, timeoutSec: 0, sound: "Basso")) }
        // 1.3 kept "urgent stays" for the rule's popup too: priority 5 stays.
        #expect(t("GitHub").band(5) == AlertBand(show: .popup, timeoutSec: 0))
        for p in 1...4 { #expect(t("GitHub").band(p) == AlertBand(show: .popup, timeoutSec: 10)) }
        for o in out.config.topics where o.label.hasPrefix("Old") {
            #expect(o.popup.position == .topRight)
            for p in 1...5 { #expect(o.band(p) == AlertBand(show: .popup, timeoutSec: 0, sound: "Basso")) }
        }
        #expect(t("Clipboard") == f.config.topic(f.ids["Clipboard"]!)!)
        for label in ["Personal", "Work", "Meetings", "Agents"] { #expect(t(label) == f.config.topic(f.ids[label]!)!) }
    }

    @Test func runtimeEquivalence() {
        let f = roysShape()
        expectEquivalent((f.config, f.rules), Migration.toV2(config: f.config, rules: f.rules, cardProviders: [Self.card]))
    }

    @Test func idempotent() {
        let f = roysShape()
        let once = Migration.toV2(config: f.config, rules: f.rules, cardProviders: [Self.card])
        let twice = Migration.toV2(config: once.config, rules: once.rules, cardProviders: [Self.card])
        #expect(twice.config == once.config && twice.rules == once.rules && twice.notes.isEmpty)
    }

    // MARK: kept verbatim

    func keeps(_ topics: [TopicConfig], _ rules: [Rule], cards: Set<String> = [card]) {
        let c = config(topics), r = RulesFile(rules: rules)
        let out = Migration.toV2(config: c, rules: r, cardProviders: cards)
        #expect(out.rules == r)
        #expect(out.config == c)
        #expect(out.notes.isEmpty)
    }

    @Test func additiveRuleIsKept() {
        let t = legacy("A")
        keeps([t], [Rule(name: "r", topicIds: [t.id], conditions: prio(">=", 4), actions: [popup(0)])])
    }

    @Test func nonPriorityConditionIsKept() {
        let t = legacy("A")
        keeps([t], [Rule(name: "r", topicIds: [t.id], conditions: prio(">=", 4) + [RuleStep("builtin.hasClick")], actions: [popup(0)], skipTopicDefaults: true)])
        keeps([t], [Rule(name: "r", topicIds: [t.id], conditions: [RuleStep("builtin.hasClick")], actions: [popup(0)], skipTopicDefaults: true)])
    }

    @Test func disabledRuleIsKept() {
        let t = legacy("A")
        keeps([t], [Rule(name: "r", topicIds: [t.id], conditions: prio(">=", 4), actions: [popup(0)], skipTopicDefaults: true, enabled: false)])
    }

    @Test func buttonParamIsKept() {
        let t = legacy("A")
        var step = popup(0)
        step.params["buttonLabel"] = .string("Docs")
        step.params["buttonURL"] = .string("https://example.com/{id}")
        keeps([t], [Rule(name: "r", topicIds: [t.id], conditions: prio(">=", 4), actions: [step], skipTopicDefaults: true)])
        keeps([t], [Rule(name: "r", topicIds: [t.id], conditions: prio(">=", 4), actions: [RuleStep("builtin.copy")], skipTopicDefaults: true)])
    }

    @Test func unknownTopicIsKept() {
        let t = legacy("A")
        keeps([t], [Rule(name: "r", topicIds: [t.id, UUID()], conditions: prio(">=", 4), actions: [popup(0)], skipTopicDefaults: true)])
    }

    @Test func overlappingBandsKeepTheSecondRule() {
        let t = legacy("A")
        let first = Rule(name: "first", topicIds: [t.id], conditions: prio(">=", 4), actions: [popup(0)], skipTopicDefaults: true)
        let second = Rule(name: "second", topicIds: [t.id], conditions: prio(">=", 3), actions: [popup(nil)], skipTopicDefaults: true)
        let out = Migration.toV2(config: config([t]), rules: RulesFile(rules: [first, second]), cardProviders: [])
        // the second rule still skips the plan on 4 and 5, so the topic can't take the first one either
        #expect(out.rules.rules.map(\.name) == ["first", "second"])
        expectEquivalent((config([t]), RulesFile(rules: [first, second])), out)
    }

    @Test func conflictingPositionKeepsTheRule() {
        let t = legacy("A")
        let high = Rule(name: "high", topicIds: [t.id], conditions: prio(">=", 4), actions: [popup(0)], skipTopicDefaults: true)
        let low = Rule(name: "low", topicIds: [t.id], conditions: prio("<=", 3), actions: [popup(10, position: "topCenter")], skipTopicDefaults: true)
        let before = (config([t]), RulesFile(rules: [high, low]))
        let out = Migration.toV2(config: before.0, rules: before.1, cardProviders: [])
        #expect(out.rules.rules.map(\.name) == ["high", "low"], "the kept rule reads the topic's popup, so the topic stays as it was")
        expectEquivalent(before, out)
    }

    @Test func enabledTopicPopupWithDifferentPositionKeepsTheRule() {
        let t = legacy("A", popup: true)
        keeps([t], [Rule(name: "r", topicIds: [t.id], conditions: prio(">=", 4), actions: [popup(0)], skipTopicDefaults: true)])
    }

    @Test func enabledTopicPopupWithTheSamePositionIsAbsorbed() {
        let t = legacy("A", popup: true)
        let r = Rule(name: "r", topicIds: [t.id], conditions: prio(">=", 4), actions: [popup(0, position: "topCenter"), basso], skipTopicDefaults: true)
        let before = (config([t]), RulesFile(rules: [r]))
        let out = Migration.toV2(config: before.0, rules: before.1, cardProviders: [])
        #expect(out.rules.rules.isEmpty)
        #expect(out.config.topics[0].band(3) == AlertBand(show: .both, timeoutSec: 20))
        expectEquivalent(before, out)
    }

    @Test func alsoActionsOnPartialCoverageRevertTheTopicAndNarrowTheRule() {
        var copying = legacy("Copying")
        copying.copyToClipboard = true
        let plain = legacy("Plain")
        let r = Rule(name: "high", topicIds: [copying.id, plain.id], conditions: prio(">=", 4), actions: [popup(0), basso], skipTopicDefaults: true)
        let before = (config([copying, plain]), RulesFile(rules: [r]))
        let out = Migration.toV2(config: before.0, rules: before.1, cardProviders: [])
        #expect(out.rules.rules.count == 1 && out.rules.rules[0].topicIds == [copying.id])
        #expect(out.config.topics[0] == copying)
        #expect(out.config.topics[1].band(4) == AlertBand(show: .popup, timeoutSec: 0, sound: "Basso"))
        #expect(out.notes == ["absorbed rule 'high' into Plain", "rule 'high' kept for 1 topic(s)"])
        expectEquivalent(before, out)
    }

    @Test func fullCoverageResetsUnreachableFlags() {
        var t = legacy("A")
        t.copyToClipboard = true
        t.command = CommandSettings(command: "echo hi")
        let rules = [Rule(name: "high", topicIds: [t.id], conditions: prio(">=", 4), actions: [popup(0)], skipTopicDefaults: true),
                     Rule(name: "low", topicIds: [t.id], conditions: prio("<=", 3), actions: [RuleStep("builtin.notify")], skipTopicDefaults: true)]
        let before = (config([t]), RulesFile(rules: rules))
        let out = Migration.toV2(config: before.0, rules: before.1, cardProviders: [])
        #expect(out.rules.rules.isEmpty)
        #expect(!out.config.topics[0].copyToClipboard && out.config.topics[0].command == nil)
        #expect(out.notes.contains("A: copyToClipboard was never reached; set to false"))
        #expect(out.config.topics[0].band(2) == AlertBand(show: .notification, timeoutSec: 20))
        expectEquivalent(before, out)
    }

    @Test func cardOnlyWhenProviderIsACard() {
        let t = legacy("A")
        keeps([t], [Rule(name: "r", topicIds: [t.id], conditions: prio(">=", 1), actions: [RuleStep(Self.card)], skipTopicDefaults: true)], cards: [])
    }

    @Test func cardNeverReplacesTheTopicsOwnPopup() {
        let t = legacy("A", popup: true)
        keeps([t], [Rule(name: "r", topicIds: [t.id], conditions: prio(">=", 4), actions: [RuleStep(Self.card)], skipTopicDefaults: true)])
    }

    @Test func keptSkipRuleOnTheTopicKeepsItsBandRules() {
        let t = legacy("A")
        keeps([t], [Rule(name: "band", topicIds: [t.id], conditions: prio(">=", 4), actions: [popup(0)], skipTopicDefaults: true),
                    Rule(name: "mute", conditions: [RuleStep("builtin.hasTag", ["tag": .string("maccyplus")])], actions: [RuleStep("builtin.ignore")])])
    }

    @Test func unknownUrgentStaysKeepsTheRule() {
        // timeout 0 everywhere: 1.3's "urgent stays" can't be read back, and it changed this rule's priority-5 timeout
        let t = legacy("A", popup: false, timeout: 0, sticky: false)
        keeps([t], [Rule(name: "r", topicIds: [t.id], conditions: prio(">=", 1), actions: [popup(10)], skipTopicDefaults: true)])
    }
}
