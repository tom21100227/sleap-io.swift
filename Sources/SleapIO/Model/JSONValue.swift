import Foundation

/// A type-preserving representation of an arbitrary JSON value.
///
/// `JSONValue` round-trips any JSON document without collapsing values to a
/// single scalar type, mirroring Python sleap-io's `dict[str, Any]` provenance
/// handling. It backs ``Labels/provenance`` so booleans, numbers, nested arrays,
/// and objects survive a save/load cycle instead of being coerced to strings.
///
/// ## Construction
///
/// Values can be written as Swift literals via the `ExpressibleBy*Literal`
/// conformances:
///
/// ```swift
/// let prov: [String: JSONValue] = [
///     "sleap_version": "1.5.0",   // .string
///     "frames": 120,              // .int
///     "fps": 29.97,               // .double
///     "trained": true,            // .bool
///     "labels": ["a", "b"],       // .array
///     "config": ["lr": 0.001],    // .object
/// ]
/// ```
///
/// - Note: JSON does not distinguish an integer from a whole-valued float, and
///   Foundation serializes `1.0` as `1`. A ``JSONValue/double(_:)`` holding a
///   whole number therefore decodes back as ``JSONValue/int(_:)`` when
///   round-tripped through JSON. Fractional doubles are preserved exactly.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    // MARK: - Convenience accessors

    /// The wrapped string, or `nil` if this value is not a ``string(_:)``.
    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// The wrapped integer, or `nil` if this value is not an ``int(_:)``.
    public var intValue: Int? {
        if case let .int(value) = self { return value }
        return nil
    }

    /// The wrapped double, or `nil` if this value is not a ``double(_:)``.
    public var doubleValue: Double? {
        if case let .double(value) = self { return value }
        return nil
    }

    /// The wrapped boolean, or `nil` if this value is not a ``bool(_:)``.
    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    /// The wrapped array, or `nil` if this value is not an ``array(_:)``.
    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// The wrapped object, or `nil` if this value is not an ``object(_:)``.
    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable as JSON"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    // MARK: - Foundation (JSONSerialization) bridge

    /// A Foundation object suitable for `JSONSerialization` / untyped `[String: Any]`
    /// dictionaries. `.null` maps to `NSNull`.
    ///
    /// This is the bridge used when emitting provenance into the SLP metadata JSON.
    public var jsonObject: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .array(let value): return value.map { $0.jsonObject }
        case .object(let value): return value.mapValues { $0.jsonObject }
        case .null: return NSNull()
        }
    }

    /// Wrap a Foundation object produced by `JSONSerialization` (or an untyped
    /// `[String: Any]` dictionary) as a `JSONValue`, preserving its JSON type.
    ///
    /// `NSNumber` values are disambiguated into ``bool(_:)``, ``int(_:)``, or
    /// ``double(_:)`` using their underlying Objective-C type so that `true`,
    /// `1`, and `1.5` are not conflated. Unrecognized objects become ``null``.
    public init(jsonObject: Any) {
        switch jsonObject {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                let type = number.objCType.pointee
                if type == CChar(UInt8(ascii: "f")) || type == CChar(UInt8(ascii: "d")) {
                    self = .double(number.doubleValue)
                } else if let intVal = Int(exactly: number) {
                    self = .int(intVal)
                } else {
                    // Integer outside Int range (e.g. > Int64.max unsigned) — preserve
                    // magnitude as a double rather than wrapping/sign-flipping.
                    self = .double(number.doubleValue)
                }
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { JSONValue(jsonObject: $0) })
        case let dict as [String: Any]:
            self = .object(dict.mapValues { JSONValue(jsonObject: $0) })
        default:
            self = .null
        }
    }
}

// MARK: - ExpressibleBy*Literal

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object: [String: JSONValue] = [:]
        for (key, value) in elements {
            object[key] = value
        }
        self = .object(object)
    }
}
