import Foundation
import Testing
@testable import NtfyBarCore

@Suite("Rules")
@MainActor
struct RuleEngineTests {
    var config = Config()
    let topicId = UUID()
    let otherTopicId = UUID()

    init() {
        config.topics = [TopicConfig(id: topicId, serverId: config.servers[0].id, topic: "ntfybar-9f3a1c7b2e", label: "Builds"),
                         TopicConfig(id: otherTopicId, serverId: config.servers[0].id, topic: "ntfybar-1d2e3f4a5b", label: "Other")]
    }

    func run(_ rules: [Rule], _ m: Message) -> RuleOutcome {
        RuleEngine(rules: rules).evaluate(m, topic: config.topic(m.topicId)!, config: config)
    }

    func cond(_ id: String, _ params: Params = [:]) -> RuleStep { RuleStep(id, params) }
    let copyTitle = RuleStep("builtin.copy", ["what": .string("title")])

    @Test func allVersusAny() {
        let m = makeMessage(topicId: topicId, title: "Disk full", priority: 5)
        let conds = [cond("builtin.titleContains", ["needle": .string("disk")]), cond("builtin.priority", ["op": .string("<="), "value": .number(2)])]
        #expect(run([Rule(name: "all", matchMode: .all, conditions: conds, actions: [copyTitle])], m).effects.isEmpty)
        #expect(run([Rule(name: "any", matchMode: .any, conditions: conds, actions: [copyTitle])], m).effects == [.copy("Disk full")])
    }

    @Test func emptyConditionsNeverMatch() {
        #expect(run([Rule(name: "x", conditions: [], actions: [copyTitle])], makeMessage(topicId: topicId)).effects.isEmpty)
    }

    @Test func disabledRulesAndTopicScope() {
        let m = makeMessage(topicId: topicId, title: "t")
        let hit = [cond("builtin.titleContains", ["needle": .string("t")])]
        #expect(run([Rule(name: "off", conditions: hit, actions: [copyTitle], enabled: false)], m).effects.isEmpty)
        #expect(run([Rule(name: "other", topicIds: [otherTopicId], conditions: hit, actions: [copyTitle])], m).effects.isEmpty)
        #expect(run([Rule(name: "mine", topicIds: [topicId], conditions: hit, actions: [copyTitle])], m).effects == [.copy("t")])
    }

    @Test func everyMatchingRuleRunsInOrder() {
        let m = makeMessage(topicId: topicId, title: "a", body: "b")
        let hit = [cond("builtin.hasClick")]
        let m2 = makeMessage(topicId: topicId, title: "a", body: "b", click: "https://example.com")
        let rules = [Rule(name: "1", conditions: hit, actions: [RuleStep("builtin.copy", ["what": .string("title")])]),
                     Rule(name: "2", conditions: hit, actions: [RuleStep("builtin.copy", ["what": .string("message")])])]
        #expect(run(rules, m).effects.isEmpty)
        #expect(run(rules, m2).effects == [.copy("a"), .copy("b")])
    }

    @Test func brokenProvidersAreNoMatchNotCrash() {
        let m = makeMessage(topicId: topicId, title: "x")
        #expect(run([Rule(name: "unknown", conditions: [cond("com.example.nope")], actions: [copyTitle])], m).effects.isEmpty)
        #expect(run([Rule(name: "badregex", conditions: [cond("builtin.titleRegex", ["pattern": .string("([")])], actions: [copyTitle])], m).effects.isEmpty)
        #expect(run([Rule(name: "missing", conditions: [cond("builtin.titleContains")], actions: [copyTitle])], m).effects.isEmpty)
        // A broken action is skipped; the next one still runs.
        let rule = Rule(name: "a", conditions: [cond("builtin.titleContains", ["needle": .string("x")])],
                        actions: [RuleStep("builtin.openURL", ["template": .string("file:///etc/passwd")]), copyTitle])
        #expect(run([rule], m).effects == [.copy("x")])
    }

    @Test func builtinConditions() {
        let m = makeMessage(topicId: topicId, title: "Backup FAILED", body: #"{"host":"nas","code":3}"#, priority: 4,
                            tags: ["Warning", "backup"], click: "https://example.com/x")
        func hit(_ id: String, _ p: Params = [:]) -> Bool {
            !run([Rule(name: id, conditions: [cond(id, p)], actions: [copyTitle])], m).effects.isEmpty
        }
        #expect(hit("builtin.priority", ["op": .string(">="), "value": .number(4)]))
        #expect(!hit("builtin.priority", ["op": .string("=="), "value": .number(5)]))
        #expect(hit("builtin.priority", ["op": .string("<="), "value": .string("4")]))
        #expect(hit("builtin.titleContains", ["needle": .string("failed")]))
        #expect(hit("builtin.titleRegex", ["pattern": .string("^Backup (OK|FAILED)$")]))
        #expect(!hit("builtin.titleRegex", ["pattern": .string("^OK")]))
        #expect(hit("builtin.messageContains", ["needle": .string("NAS")]))
        #expect(hit("builtin.messageRegex", ["pattern": .string(#""code":\s*3"#)]))
        #expect(hit("builtin.hasTag", ["tag": .string("warning")]))
        #expect(!hit("builtin.hasTag", ["tag": .string("skull")]))
        #expect(hit("builtin.hasClick"))
        #expect(!hit("builtin.hasAttachment"))
        #expect(hit("builtin.isJSON"))
        let plain = makeMessage(topicId: topicId, body: "42")
        #expect(run([Rule(name: "j", conditions: [cond("builtin.isJSON")], actions: [copyTitle])], plain).effects.isEmpty, "a bare number is not a JSON document")
    }

    @Test func builtinActions() throws {
        let m = makeMessage(topicId: topicId, title: "Hi & bye", body: "body text", priority: 5, tags: ["a", "b"], click: "https://example.com/c")
        func out(_ id: String, _ p: Params = [:]) -> RuleOutcome {
            run([Rule(name: id, conditions: [cond("builtin.priority", ["value": .number(1)])], actions: [RuleStep(id, p)])], m)
        }
        #expect(out("builtin.notify").effects == [.notify(m, label: "Builds")])
        #expect(out("builtin.copy", ["what": .string("message")]).effects == [.copy("body text")])
        #expect(out("builtin.copy", ["what": .string("click")]).effects == [.copy("https://example.com/c")])
        #expect(out("builtin.copy", ["what": .string("json")]).effects == [.copy(m.raw)])
        #expect(out("builtin.copy", ["what": .string("template"), "template": .string("{topicLabel}: {title} ({tags})")]).effects
                == [.copy("Builds: Hi & bye (a,b)")])
        #expect(out("builtin.openClick").effects == [.openURL(URL(string: "https://example.com/c")!)])
        #expect(out("builtin.openURL", ["template": .string("https://example.com/s?q={title}")]).effects
                == [.openURL(URL(string: "https://example.com/s?q=Hi%20%26%20bye")!)])
        #expect(out("builtin.openURL", ["template": .string("shortcuts://run?x={title}")]).effects.isEmpty, "non-http(s) refused")
        #expect(out("builtin.runShortcut", ["name": .string("My Shortcut")]).effects == [.runShortcut(name: "My Shortcut", m)])
        #expect(out("builtin.playSound", ["name": .string("Glass")]).effects == [.playSound("Glass")])
        #expect(out("builtin.ignore").skipTopicDefaults)
        if case let .runCommand(settings, _, label) = try #require(out("builtin.runCommand", ["command": .string("echo hi"), "timeoutSec": .number(5)]).effects.first) {
            #expect(settings == CommandSettings(command: "echo hi", timeoutSec: 5, notifyOnFailure: true))
            #expect(label == "Builds")
        } else { Issue.record("no command") }
        if case let .popup(req) = try #require(out("builtin.popup", ["timeoutSec": .number(0), "position": .string("topRight"),
                                                                     "buttonLabel": .string("Docs"), "buttonURL": .string("https://example.com/{id}")]).effects.first) {
            #expect(req.settings.enabled && req.settings.timeoutSec == 0 && req.settings.position == .topRight)
            #expect(req.extraButtons.first?.openURL == "https://example.com/\(m.ntfy.id)")
        } else { Issue.record("no popup") }
        let pub = out("builtin.publish", ["topicId": .string(otherTopicId.uuidString), "title": .string("Re: {title}"),
                                          "message": .string("seen {id}"), "priority": .number(9), "tags": .string("eyes, done")]).effects
        #expect(pub == [.publish(PublishRequest(topicId: otherTopicId, title: "Re: Hi & bye", message: "seen \(m.ntfy.id)", priority: 5, tags: ["eyes", "done"]))])
        #expect(out("builtin.publish", ["topicId": .string(UUID().uuidString), "message": .string("x")]).effects.isEmpty, "unknown topic refused")
    }

    @Test func skipTopicDefaultsThroughDispatcher() {
        var c = config
        c.topics[0].alerts = AlertBand.expand(notify: true, popup: { var p = PopupSettings(); p.enabled = true; return p }(), soundOverride: nil)
        let rule = Rule(name: "quiet", conditions: [cond("builtin.titleContains", ["needle": .string("noise")])],
                        actions: [RuleStep("builtin.copy", ["what": .string("title")])], skipTopicDefaults: true)
        let d = Dispatcher(rules: RuleEngine(rules: [rule]))
        #expect(d.handle(makeMessage(topicId: topicId, title: "noise"), config: c, now: Date()) == [.copy("noise")])
        let viaIgnore = Dispatcher(rules: RuleEngine(rules: [Rule(name: "i", conditions: [cond("builtin.titleContains", ["needle": .string("noise")])],
                                                                  actions: [RuleStep("builtin.ignore")])]))
        #expect(viaIgnore.handle(makeMessage(topicId: topicId, title: "noise"), config: c, now: Date()).isEmpty)
    }

    @Test func builtinPopupInheritsTheBandTimeout() {
        var c = config
        c.topics[0].alerts["4"] = AlertBand(show: .popup, timeoutSec: 0)
        let m = makeMessage(topicId: topicId, priority: 4)
        let ctx = ProviderContext(message: m, topic: c.topics[0], config: c)
        func timeout(_ p: Params) -> Int? {
            guard case let .popup(req)? = try? ProviderRegistry().run("builtin.popup", ctx, p).effects.first else { return nil }
            return req.settings.timeoutSec
        }
        #expect(timeout([:]) == 0)
        #expect(timeout(["timeoutSec": .number(7)]) == 7)
    }

    @Test func catchUpSkipsRulesUnlessProcessMissed() {
        let rule = Rule(name: "r", conditions: [cond("builtin.priority", ["value": .number(1)])], actions: [copyTitle])
        let d = Dispatcher(rules: RuleEngine(rules: [rule]))
        #expect(d.handle(makeMessage(topicId: topicId, title: "x", isCatchUp: true), config: config, now: Date()).isEmpty)
    }

    @Test func rulesFileRoundTripsAndToleratesJunk() throws {
        let r = RulesFile(rules: [Rule(name: "r", topicIds: [topicId], matchMode: .any, conditions: [cond("builtin.hasClick")],
                                       actions: [copyTitle], skipTopicDefaults: true)])
        let back = try ConfigStore.decoder.decode(RulesFile.self, from: ConfigStore.encoder.encode(r))
        #expect(back == r)
        let junk = #"{"rules":[{"name":"half","matchMode":"sometimes","conditions":[{"providerId":"builtin.hasClick"}]}]}"#
        let parsed = try JSONDecoder().decode(RulesFile.self, from: Data(junk.utf8))
        #expect(parsed.schemaVersion == 1 && parsed.rules[0].matchMode == .all && parsed.rules[0].conditions.count == 1)
    }
}

@Suite("Templates")
struct TemplateTests {
    let m = makeMessage(topicId: UUID(), id: "abc", time: 1_700_000_000, title: "T {message}", body: "a&b=c?d#e/f g+h ü",
                        priority: 4, tags: ["x", "y"], click: "https://example.com")

    @Test func placeholders() {
        #expect(Template.render("{title}|{message}|{priority}|{tags}|{click}|{topicLabel}|{id}|{time}", message: m, topicLabel: "L")
                == "T {message}|a&b=c?d#e/f g+h ü|4|x,y|https://example.com|L|abc|1700000000")
    }

    @Test func singlePassNoReexpansion() {
        #expect(Template.render("{title}", message: m, topicLabel: "L") == "T {message}")
    }

    @Test func unknownAndUnclosedBracesStay() {
        #expect(Template.render("{nope} {title {", message: m, topicLabel: "L") == "{nope} {title {")
    }

    @Test func urlEncodingEncodesEveryReservedCharacter() {
        #expect(Template.render("https://x.example/?q={message}", message: m, topicLabel: "L", urlEncode: true)
                == "https://x.example/?q=a%26b%3Dc%3Fd%23e%2Ff%20g%2Bh%20%C3%BC")
    }
}
