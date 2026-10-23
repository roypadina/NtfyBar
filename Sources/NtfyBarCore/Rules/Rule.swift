import Foundation

/// One condition or action in a rule: a provider id plus its parameters.
public struct RuleStep: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var providerId: String
    public var params: Params

    public init(id: UUID = UUID(), _ providerId: String, _ params: Params = [:]) {
        self.id = id
        self.providerId = providerId
        self.params = params
    }

    private enum CodingKeys: String, CodingKey { case id, providerId, params }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        providerId = c.value(.providerId, "")
        params = c.value(.params, [:])
    }
}

public struct Rule: Codable, Equatable, Sendable, Identifiable {
    public enum MatchMode: String, Codable, Sendable, CaseIterable { case all, any }

    public var id: UUID
    public var name: String
    public var enabled = true
    /// Empty = every topic.
    public var topicIds: [UUID] = []
    public var matchMode: MatchMode = .all
    public var conditions: [RuleStep] = []
    public var actions: [RuleStep] = []
    public var skipTopicDefaults = false

    public init(id: UUID = UUID(), name: String, topicIds: [UUID] = [], matchMode: MatchMode = .all,
                conditions: [RuleStep] = [], actions: [RuleStep] = [], skipTopicDefaults: Bool = false, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.topicIds = topicIds
        self.matchMode = matchMode
        self.conditions = conditions
        self.actions = actions
        self.skipTopicDefaults = skipTopicDefaults
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case id, name, enabled, topicIds, matchMode, conditions, actions, skipTopicDefaults }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        name = c.value(.name, "Untitled rule")
        enabled = c.value(.enabled, true)
        topicIds = c.value(.topicIds, [])
        matchMode = c.value(.matchMode, .all)
        conditions = c.value(.conditions, [])
        actions = c.value(.actions, [])
        skipTopicDefaults = c.value(.skipTopicDefaults, false)
    }
}

/// rules.json — hand-editable ("Edit rules file…").
public struct RulesFile: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var rules: [Rule] = []

    public init(rules: [Rule] = []) {
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, rules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.value(.schemaVersion, 1)
        rules = c.value(.rules, [])
    }
}

extension ConfigStore {
    public func loadRules() -> RulesFile { load(RulesFile.self, from: rulesURL) ?? RulesFile() }
    public func saveRules(_ rules: RulesFile) throws { try save(rules, to: rulesURL) }
}
