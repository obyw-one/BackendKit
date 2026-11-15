import Foundation
@_spi(CodableUtilities) import SQLKit

// MARK: - DuckDBValue

/// A result cell, already extracted from the DuckDB result set (Sendable, engine-free).
enum DuckDBValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case decimal(Decimal)
    case string(String)
    case blob(Data)
    case date(Date)
}

/// Failures of the bind (encode) and row (decode) paths, and of DuckDB itself.
public enum DuckDBSQLError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedBind(String)
    case missingColumn(String)
    case typeMismatch(String)
    /// DuckDB rejected the operation (open, prepare, bind or execute); carries DuckDB's own error text, unmodified.
    case engine(String)
    /// A result column has a DuckDB type this package does not decode. Nothing is dropped or turned into NULL:
    /// cast the column to a supported type (e.g. `CAST(x AS VARCHAR)`) in the query.
    case unsupportedColumnType(column: String, type: String)
    /// The host was shut down.
    case shutDown

    public var errorDescription: String? {
        switch self {
        case .unsupportedBind(let detail): "DuckDB: cannot bind \(detail)"
        case .missingColumn(let name): "DuckDB: no column named \(name)"
        case .typeMismatch(let detail): "DuckDB: type mismatch: \(detail)"
        case .engine(let message): message
        case .unsupportedColumnType(let column, let type):
            "DuckDB: column \"\(column)\" has type \(type), which BackendKitDuckDB does not decode; CAST it to a supported type in the query"
        case .shutDown: "DuckDB: the host is shut down"
        }
    }
}

// MARK: - Encoding (Swift value → bound parameter)

enum DuckDBBindEncoder {
    static func encode(_ value: any Encodable) throws -> DuckDBValue {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let inner = mirror.children.first?.value else { return .null }
            guard let encodable = inner as? any Encodable else {
                throw DuckDBSQLError.unsupportedBind("\(type(of: inner))")
            }
            return try encode(encodable)
        }
        if let scalar = scalar(value) { return scalar }
        return try viaJSON(value)
    }

    private static func scalar(_ value: any Encodable) -> DuckDBValue? {
        switch value {
        case let v as Bool: .bool(v)
        case let v as any FixedWidthInteger: Int64(exactly: v).map { .int($0) } ?? .string("\(v)")
        case let v as any BinaryFloatingPoint: .double(Double(v))
        case let v as String: .string(v)
        case let v as UUID: .string(v.uuidString)
        case let v as Date: .date(v)
        case let v as Data: .blob(v)
        case let v as Decimal: .decimal(v)
        default: wrapped(value)
        }
    }

    /// SQLKit hands a model's `Decimal`, `Date` and `Data` fields to the driver inside its `FakeSendableCodable` wrapper
    /// (they are not `Sendable`). Without unwrapping them they would fall through to the JSON route below and arrive as
    /// a Double: a Decimal would silently lose every digit a Double cannot hold, and a Date could not be bound as a
    /// timestamp at all.
    private static func wrapped(_ value: any Encodable) -> DuckDBValue? {
        switch value {
        case let v as FakeSendableCodable<Decimal>: .decimal(v.value)
        case let v as FakeSendableCodable<Date>: .date(v.value)
        case let v as FakeSendableCodable<Data>: .blob(v.value)
        default: nil
        }
    }

    /// RawRepresentable enums, wrappers and Codable structs: encode as a JSON fragment; a scalar
    /// fragment binds as that scalar, an object/array binds as its (key-sorted) JSON text.
    ///
    /// The kind of the fragment is read from the encoder's own compact output, never from a Foundation
    /// object tree: `JSONSerialization` hands numbers and booleans back as `NSNumber`, and telling a
    /// JSON `true` from a JSON `1` there needs a CoreFoundation call (`CFBooleanGetTypeID`) that Linux
    /// does not have. `true`/`false` is a bool token, `1`/`0` is a number token, on every platform.
    private static func viaJSON(_ value: any Encodable) throws -> DuckDBValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let envelope = try encoder.encode(DuckDBBox(value))
        let opening = Data("{\"v\":".utf8)
        guard envelope.starts(with: opening), envelope.last == UInt8(ascii: "}") else {
            throw DuckDBSQLError.unsupportedBind("\(type(of: value)) produced an unexpected JSON envelope")
        }
        return try bound(token: Data(envelope.dropFirst(opening.count).dropLast()), of: type(of: value))
    }

    /// The bound parameter for one JSON value token (the text of the `v` member).
    static func bound(token: Data, of type: Any.Type) throws -> DuckDBValue {
        guard let first = token.first else {
            throw DuckDBSQLError.unsupportedBind("\(type) produced an empty JSON value")
        }
        switch first {
        case UInt8(ascii: "n"): return try literal("null", .null, token, type)
        case UInt8(ascii: "t"): return try literal("true", .bool(true), token, type)
        case UInt8(ascii: "f"): return try literal("false", .bool(false), token, type)
        case UInt8(ascii: "\""): return .string(try JSONDecoder().decode(String.self, from: token))
        case UInt8(ascii: "{"), UInt8(ascii: "["): return .string(try text(of: token, type))
        default: return try number(try text(of: token, type), type)
        }
    }

    /// A bare JSON literal: the whole token must BE the literal, not merely start with its first letter.
    private static func literal(_ expected: String, _ value: DuckDBValue, _ token: Data, _ type: Any.Type) throws -> DuckDBValue {
        guard token == Data(expected.utf8) else {
            throw DuckDBSQLError.unsupportedBind("\(type) produced an unrecognised JSON literal: \(String(bytes: token, encoding: .utf8) ?? "\(token.count) non-UTF8 bytes")")
        }
        return value
    }

    private static func text(of token: Data, _ type: Any.Type) throws -> String {
        guard let text = String(bytes: token, encoding: .utf8) else {
            throw DuckDBSQLError.unsupportedBind("\(type) produced non-UTF8 JSON")
        }
        return text
    }

    private static func number(_ text: String, _ type: Any.Type) throws -> DuckDBValue {
        if let integer = Int64(text) { return .int(integer) }
        if let double = Double(text) { return .double(double) }
        throw DuckDBSQLError.unsupportedBind("\(type) produced an unrecognised JSON number: \(text)")
    }
}

private struct DuckDBBox: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    private enum Keys: String, CodingKey { case v }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(value, forKey: .v)
    }
}

private struct DuckDBFragment<T: Decodable>: Decodable {
    let v: T
}

// MARK: - Decoding (result cell → Swift value)

enum DuckDBValueDecoder {
    static func decode<T: Decodable>(_ type: T.Type, from value: DuckDBValue) throws -> T {
        let decoder = JSONDecoder()
        if let scalar = try scalar(type, from: value) { return scalar }
        // Representation cascade: scalar JSON fragment -> JSON text/blob -> a thrown `typeMismatch`.
        // A representation that does not fit is not discarded: the fragment probe's own decode error is
        // kept and goes into the final error, so a value that fits no representation says WHY.
        // Optionals, RawRepresentable enums and wrappers: through a JSON scalar fragment.
        let fragmentFailure: String
        if let fragment = try fragment(of: value) {
            do {
                return try decoder.decode(DuckDBFragment<T>.self, from: fragment).v
            } catch {
                fragmentFailure = "JSON-fragment probe failed: \(describe(error))"
            }
        } else {
            fragmentFailure = "the cell has no JSON-fragment form"
        }
        // A struct/array stored as JSON text (or blob): its decode error is itself the cause, and propagates.
        switch value {
        case .string(let s): return try decoder.decode(T.self, from: Data(s.utf8))
        case .blob(let d): return try decoder.decode(T.self, from: d)
        default: throw DuckDBSQLError.typeMismatch("\(value) as \(T.self): \(fragmentFailure)")
        }
    }

    /// A decode failure as one line: the library's own reason and where in the value it happened.
    private static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        let context: DecodingError.Context
        switch decoding {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c):
            context = c
        @unknown default:
            return "\(decoding)"
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return "\(context.debugDescription) (at \(path.isEmpty ? "<root>" : path))"
    }

    /// The JSON scalar-fragment form of a cell, or nil when the cell has none (applicability, not an error).
    private static func fragment(of value: DuckDBValue) throws -> Data? {
        let json: String
        switch value {
        case .null: json = "null"
        case .bool(let b): json = b ? "true" : "false"
        case .int(let i): json = String(i)
        case .double(let d):
            // JSON has no NaN/Infinity: turning them into `null` would silently change the value.
            guard d.isFinite else { throw DuckDBSQLError.typeMismatch("non-finite double \(d) has no JSON fragment form") }
            json = "\(d)"
        case .decimal(let d): json = "\(d)"
        case .string(let s):
            let data = try JSONEncoder().encode([s])
            guard let text = String(bytes: data.dropFirst().dropLast(), encoding: .utf8) else {
                throw DuckDBSQLError.typeMismatch("\(value) produced non-UTF8 JSON")
            }
            json = text
        case .date, .blob: return nil  // not applicable: handled by the scalar / JSON-text path, else the default throws
        }
        return Data("{\"v\":\(json)}".utf8)
    }

    private static func scalar<T>(_ type: T.Type, from value: DuckDBValue) throws -> T? {
        if value != .null, let optional = try optionalScalar(type, from: value) { return optional }
        if type == Bool.self { return try bool(value) as? T }
        if let integerType = type as? any FixedWidthInteger.Type { return try integer(integerType, value) as? T }
        if type == Double.self { return try double(value) as? T }
        if type == Float.self { return Float(try double(value)) as? T }
        if type == Decimal.self { return try decimal(value) as? T }
        if type == String.self { return try string(value) as? T }
        if type == UUID.self { return try uuid(value) as? T }
        if type == Date.self { return try date(value) as? T }
        if type == Data.self { return try data(value) as? T }
        return nil
    }

    /// `Decimal?`, `Date?` and `Data?` decode their wrapped scalar exactly like the non-optional form. The JSON-fragment
    /// route cannot serve them: it would carry a Decimal through a JSON number (losing digits beyond what a Double
    /// holds, silently) and has no fragment at all for a Date or a Data.
    private static func optionalScalar<T>(_ type: T.Type, from value: DuckDBValue) throws -> T? {
        if type == Decimal?.self { return try decimal(value) as? T }
        if type == Date?.self { return try date(value) as? T }
        if type == Data?.self { return try data(value) as? T }
        return nil
    }

    private static func mismatch(_ value: DuckDBValue, _ target: Any.Type) -> DuckDBSQLError {
        .typeMismatch("\(value) as \(target)")
    }

    private static func bool(_ value: DuckDBValue) throws -> Bool {
        switch value {
        case .bool(let b): return b
        case .int(let i): return i != 0
        default: throw mismatch(value, Bool.self)
        }
    }

    private static func integer<I: FixedWidthInteger>(_ type: I.Type, _ value: DuckDBValue) throws -> I {
        switch value {
        case .int(let i): if let r = I(exactly: i) { return r }
        case .double(let d): if let r = I(exactly: d) { return r }
        case .bool(let b): return b ? 1 : 0
        case .string(let s): if let r = I(s) { return r }
        default: break
        }
        throw mismatch(value, type)
    }

    private static func double(_ value: DuckDBValue) throws -> Double {
        switch value {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .decimal(let d): return NSDecimalNumber(decimal: d).doubleValue
        case .string(let s): if let d = Double(s) { return d }
        default: break
        }
        throw mismatch(value, Double.self)
    }

    private static func decimal(_ value: DuckDBValue) throws -> Decimal {
        switch value {
        case .decimal(let d): return d
        case .int(let i): return Decimal(i)
        case .double(let d): return Decimal(d)
        case .string(let s): if let d = Decimal(string: s) { return d }
        default: break
        }
        throw mismatch(value, Decimal.self)
    }

    private static func string(_ value: DuckDBValue) throws -> String {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .decimal(let d): return "\(d)"
        case .bool(let b): return String(b)
        default: throw mismatch(value, String.self)
        }
    }

    private static func uuid(_ value: DuckDBValue) throws -> UUID {
        if case .string(let s) = value, let u = UUID(uuidString: s) { return u }
        throw mismatch(value, UUID.self)
    }

    private static func date(_ value: DuckDBValue) throws -> Date {
        switch value {
        case .date(let d): return d
        case .double(let d): return Date(timeIntervalSince1970: d)
        default: throw mismatch(value, Date.self)
        }
    }

    private static func data(_ value: DuckDBValue) throws -> Data {
        switch value {
        case .blob(let d): return d
        case .string(let s): return Data(s.utf8)
        default: throw mismatch(value, Data.self)
        }
    }
}

// MARK: - SQLRow

struct DuckDBSQLRow: SQLRow {
    let columns: [String]
    let values: [DuckDBValue]

    var allColumns: [String] { columns }

    func contains(column: String) -> Bool { columns.contains(column) }

    func decodeNil(column: String) throws -> Bool {
        guard let index = columns.firstIndex(of: column) else { return true }
        return values[index] == .null
    }

    func decode<D: Decodable>(column: String, as: D.Type) throws -> D {
        guard let index = columns.firstIndex(of: column) else { throw DuckDBSQLError.missingColumn(column) }
        return try DuckDBValueDecoder.decode(D.self, from: values[index])
    }
}
