import Foundation

/// Any JSON value: rule params, plugin state and storage.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n): try c.encode(n)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    public var string: String? {
        switch self {
        case let .string(s): s
        case let .number(n): n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case let .bool(b): String(b)
        default: nil
        }
    }

    public var int: Int? {
        switch self {
        case let .number(n): n.isFinite ? Int(n) : nil
        case let .string(s): Int(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    public var bool: Bool? {
        switch self {
        case let .bool(b): b
        case let .string(s): ["true", "yes", "1"].contains(s.lowercased()) ? true : ["false", "no", "0"].contains(s.lowercased()) ? false : nil
        case let .number(n): n != 0
        default: nil
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    /// JSON text, compact with sorted keys.
    public var jsonText: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    public static func parse(_ text: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}

public typealias Params = [String: JSONValue]

extension Dictionary where Key == String, Value == JSONValue {
    public func string(_ key: String) -> String? { self[key]?.string }
    public func int(_ key: String) -> Int? { self[key]?.int }
    public func bool(_ key: String) -> Bool? { self[key]?.bool }
}
