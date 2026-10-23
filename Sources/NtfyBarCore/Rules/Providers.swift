import Foundation

public enum ProviderKind: String, Codable, Sendable { case condition, action }

public struct ParamSpec: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, number, bool, topic, choice }

    public var key: String
    public var label: String
    public var kind: Kind
    public var placeholder: String?
    /// Only for `choice` (built-in providers).
    public var choices: [String]?

    public init(_ key: String, _ label: String, _ kind: Kind = .text, placeholder: String? = nil, choices: [String]? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.placeholder = placeholder
        self.choices = choices
    }
}

public struct ProviderDescriptor: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: ProviderKind
    public var name: String
    public var description: String
    public var params: [ParamSpec]
    /// "builtin", or the plugin package id that provides it.
    public var packageId: String?

    public init(id: String, kind: ProviderKind, name: String, description: String, params: [ParamSpec] = [], packageId: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.description = description
        self.params = params
        self.packageId = packageId
    }
}

public struct ProviderContext: Sendable {
    public var message: Message
    public var topic: TopicConfig
    public var config: Config

    public init(message: Message, topic: TopicConfig, config: Config) {
        self.message = message
        self.topic = topic
        self.config = config
    }

    public var label: String { topic.displayLabel }
}

public struct ActionOutput: Equatable, Sendable {
    public var effects: [Effect]
    public var suppressDefaults: Bool

    public init(_ effects: [Effect] = [], suppressDefaults: Bool = false) {
        self.effects = effects
        self.suppressDefaults = suppressDefaults
    }
}

public enum ProviderError: Error, Equatable, CustomStringConvertible {
    case unknownProvider(String)
    case badParams(String)
    case failed(String)

    public var description: String {
        switch self {
        case let .unknownProvider(id): "unknown provider \(id)"
        case let .badParams(s): "bad parameters: \(s)"
        case let .failed(s): s
        }
    }
}

/// Every condition and action the rule engine can call: built-ins plus whatever plugins register.
@MainActor
public final class ProviderRegistry {
    public typealias Condition = @MainActor (ProviderContext, Params) throws -> Bool
    public typealias Action = @MainActor (ProviderContext, Params) throws -> ActionOutput

    public private(set) var descriptors: [String: ProviderDescriptor] = [:]
    private var conditions: [String: Condition] = [:]
    private var actions: [String: Action] = [:]

    public init(builtins: Bool = true) {
        if builtins { BuiltinProviders.register(in: self) }
    }

    public func register(_ d: ProviderDescriptor, condition: @escaping Condition) {
        descriptors[d.id] = d
        conditions[d.id] = condition
    }

    public func register(_ d: ProviderDescriptor, action: @escaping Action) {
        descriptors[d.id] = d
        actions[d.id] = action
    }

    /// Drops every provider that came from a plugin (before a reload).
    public func removePluginProviders() {
        for (id, d) in descriptors where d.packageId != nil {
            descriptors[id] = nil
            conditions[id] = nil
            actions[id] = nil
        }
    }

    public func evaluate(_ id: String, _ ctx: ProviderContext, _ params: Params) throws -> Bool {
        guard let fn = conditions[id] else { throw ProviderError.unknownProvider(id) }
        return try fn(ctx, params)
    }

    public func run(_ id: String, _ ctx: ProviderContext, _ params: Params) throws -> ActionOutput {
        guard let fn = actions[id] else { throw ProviderError.unknownProvider(id) }
        return try fn(ctx, params)
    }

    public func catalog(_ kind: ProviderKind) -> [ProviderDescriptor] {
        descriptors.values.filter { $0.kind == kind }.sorted { ($0.packageId ?? "", $0.name) < ($1.packageId ?? "", $1.name) }
    }
}

extension Params {
    func required(_ key: String) throws -> String {
        guard let s = string(key), !s.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ProviderError.badParams("\(key) is required")
        }
        return s
    }
}
