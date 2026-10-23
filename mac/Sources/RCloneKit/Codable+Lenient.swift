import Foundation

// MARK: - JSONValue

/// Arbitrary JSON, used for `Field.default`, `accounts.add.continue` answers and untyped results.
public enum JSONValue: Codable, Equatable, Hashable, Sendable {
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
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 9e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s == "true"
        case .number(let n): return n != 0
        default: return nil
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

// MARK: - Lenient enums

/// String enums that decode unknown raw values to a fallback instead of failing the whole payload.
/// The daemon is developed in parallel; a new state string must never blank the UI.
public protocol LenientEnum: RawRepresentable, Codable, CaseIterable, Sendable, Hashable where RawValue == String {
    static var fallback: Self { get }
}

public extension LenientEnum {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.fallback
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - Defaults for missing keys

public protocol DefaultValueProvider {
    associatedtype Value: Codable & Equatable & Sendable
    static var defaultValue: Value { get }
}

/// Decodes a missing (or null) key as the provider's default; always encodes the value.
@propertyWrapper
public struct Default<P: DefaultValueProvider>: Codable, Equatable, Sendable {
    public var wrappedValue: P.Value
    public init(wrappedValue: P.Value) { self.wrappedValue = wrappedValue }
    public init() { wrappedValue = P.defaultValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = c.decodeNil() ? P.defaultValue : ((try? c.decode(P.Value.self)) ?? P.defaultValue)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    public func decode<P>(_ type: Default<P>.Type, forKey key: Key) throws -> Default<P> {
        try decodeIfPresent(type, forKey: key) ?? Default()
    }

    public func decode<T>(_ type: Nullable<T>.Type, forKey key: Key) throws -> Nullable<T> {
        try decodeIfPresent(type, forKey: key) ?? Nullable(wrappedValue: nil)
    }
}

/// An optional that is encoded as an explicit JSON `null` (so `jobs.update` patches can clear values)
/// and decodes a missing key as nil.
@propertyWrapper
public struct Nullable<T: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var wrappedValue: T?
    public init(wrappedValue: T?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = c.decodeNil() ? nil : try? c.decode(T.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let wrappedValue { try c.encode(wrappedValue) } else { try c.encodeNil() }
    }
}

public enum False: DefaultValueProvider { public static var defaultValue: Bool { false } }
public enum True: DefaultValueProvider { public static var defaultValue: Bool { true } }
public enum Zero: DefaultValueProvider { public static var defaultValue: Int64 { 0 } }
public enum ZeroInt: DefaultValueProvider { public static var defaultValue: Int { 0 } }
public enum ZeroDouble: DefaultValueProvider { public static var defaultValue: Double { 0 } }
public enum EmptyString: DefaultValueProvider { public static var defaultValue: String { "" } }
public enum EmptyList<T: Codable & Equatable & Sendable>: DefaultValueProvider { public static var defaultValue: [T] { [] } }
public enum FallbackCase<E: LenientEnum>: DefaultValueProvider { public static var defaultValue: E { E.fallback } }

// MARK: - Dates

public enum RFC3339 {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let lock = NSLock()

    public static func date(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: string) ?? plain.date(from: string)
    }

    public static func string(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return plain.string(from: date)
    }
}

extension Default: Hashable where P.Value: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(wrappedValue) }
}
extension Nullable: Hashable where T: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(wrappedValue) }
}

public enum Ten: DefaultValueProvider { public static var defaultValue: Int { 10 } }
public enum Four: DefaultValueProvider { public static var defaultValue: Int { 4 } }
public enum Eight: DefaultValueProvider { public static var defaultValue: Int { 8 } }
public enum TwentyFive: DefaultValueProvider { public static var defaultValue: Int { 25 } }
public enum Thirty: DefaultValueProvider { public static var defaultValue: Int { 30 } }
public enum InfoLevel: DefaultValueProvider { public static var defaultValue: String { "info" } }
public enum RecommendedPresets: DefaultValueProvider { public static var defaultValue: [String] { ["vcs", "ide", "deps", "osjunk"] } }
