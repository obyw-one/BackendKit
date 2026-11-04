import Foundation
import SQLKit

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

/// Failures of the bind (encode) and row (decode) paths.
public enum DuckDBSQLError: Error, Sendable, Equatable {
    case unsupportedBind(String)
    case missingColumn(String)
    case typeMismatch(String)
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
        default: nil
        }
    }

    /// RawRepresentable enums, wrappers and Codable structs: encode as a JSON fragment; a scalar
    /// fragment binds as that scalar, an object/array binds as its JSON text.
    private static func viaJSON(_ value: any Encodable) throws -> DuckDBValue {
        let encoder = JSONEncoder()
        let data = try encoder.encode(DuckDBBox(value))
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let wrapped = (object as? [String: Any])?["v"] else {
            throw DuckDBSQLError.unsupportedBind("\(type(of: value))")
        }
        switch wrapped {
        case is NSNull: return .null
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return Int64(exactly: n).map { .int($0) } ?? .double(n.doubleValue)
        default:
            let inner = try JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys])
            guard let text = String(bytes: inner, encoding: .utf8) else {
                throw DuckDBSQLError.unsupportedBind("\(type(of: value)) produced non-UTF8 JSON")
            }
            return .string(text)
        }
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
        // Cascading representation probe: scalar fragment -> JSON text/blob -> the final `default:` throws
        // `typeMismatch`. The `try?` only means "this representation did not fit, try the next".
        // Optionals, RawRepresentable enums and wrappers: through a JSON scalar fragment.
        if let fragment = try fragment(of: value),
           let decoded = try? decoder.decode(DuckDBFragment<T>.self, from: fragment).v {
            return decoded
        }
        // A struct/array stored as JSON text (or blob).
        switch value {
        case .string(let s): return try decoder.decode(T.self, from: Data(s.utf8))
        case .blob(let d): return try decoder.decode(T.self, from: d)
        default: throw DuckDBSQLError.typeMismatch("\(value) as \(T.self)")
        }
    }

    /// The JSON scalar-fragment form of a cell, or nil when the cell has none (applicability, not an error).
    private static func fragment(of value: DuckDBValue) throws -> Data? {
        let json: String
        switch value {
        case .null: json = "null"
        case .bool(let b): json = b ? "true" : "false"
        case .int(let i): json = String(i)
        case .double(let d): json = d.isFinite ? "\(d)" : "null"
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
