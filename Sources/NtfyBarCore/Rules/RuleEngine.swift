import Foundation

public struct RuleOutcome: Equatable, Sendable {
    public var effects: [Effect] = []
    public var skipTopicDefaults = false

    public init(effects: [Effect] = [], skipTopicDefaults: Bool = false) {
        self.effects = effects
        self.skipTopicDefaults = skipTopicDefaults
    }
}

/// Every enabled rule whose topic scope and conditions match runs, top to bottom. A rule with no
/// conditions never matches. A failing provider (bad params, plugin error) counts as "no match"
/// for a condition and is skipped for an action — logged, never fatal.
@MainActor
public struct RuleEngine {
    public var rules: [Rule]
    public let registry: ProviderRegistry

    public init(rules: [Rule] = [], registry: ProviderRegistry = ProviderRegistry()) {
        self.rules = rules
        self.registry = registry
    }

    public func evaluate(_ m: Message, topic: TopicConfig, config: Config) -> RuleOutcome {
        let ctx = ProviderContext(message: m, topic: topic, config: config)
        var outcome = RuleOutcome()
        for rule in rules where rule.enabled && (rule.topicIds.isEmpty || rule.topicIds.contains(topic.id)) {
            guard matches(rule, ctx) else { continue }
            if rule.skipTopicDefaults { outcome.skipTopicDefaults = true }
            for step in rule.actions {
                do {
                    let out = try registry.run(step.providerId, ctx, step.params)
                    outcome.effects += out.effects
                    if out.suppressDefaults { outcome.skipTopicDefaults = true }
                } catch {
                    Log.dispatch.error("rule \"\(rule.name, privacy: .public)\" action \(step.providerId, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
        return outcome
    }

    private func matches(_ rule: Rule, _ ctx: ProviderContext) -> Bool {
        guard !rule.conditions.isEmpty else { return false }
        let check: (RuleStep) -> Bool = { step in
            do {
                return try registry.evaluate(step.providerId, ctx, step.params)
            } catch {
                Log.dispatch.error("rule \"\(rule.name, privacy: .public)\" condition \(step.providerId, privacy: .public): \(String(describing: error), privacy: .public)")
                return false
            }
        }
        return rule.matchMode == .all ? rule.conditions.allSatisfy(check) : rule.conditions.contains(where: check)
    }
}
