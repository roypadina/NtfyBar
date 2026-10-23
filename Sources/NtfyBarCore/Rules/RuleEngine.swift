import Foundation

public struct RuleOutcome: Equatable, Sendable {
    public var effects: [Effect] = []
    public var skipTopicDefaults = false

    public init(effects: [Effect] = [], skipTopicDefaults: Bool = false) {
        self.effects = effects
        self.skipTopicDefaults = skipTopicDefaults
    }
}

// shortcut: M1 placeholder — rules arrive in M2a.
@MainActor
public struct RuleEngine {
    public init() {}

    public func evaluate(_ m: Message, topic: TopicConfig, config: Config) -> RuleOutcome { RuleOutcome() }
}
