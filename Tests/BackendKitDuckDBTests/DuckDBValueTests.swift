#if BACKENDKIT_DUCKDB
import Foundation
import Testing
@testable import BackendKitDuckDB

// MARK: - Fixtures

/// A value that encodes as ONE bare JSON scalar, so it reaches the bind encoder's JSON path
/// (a plain `Bool`/`Int` is caught earlier, by its own scalar case).
private struct Bare<Wrapped: Encodable & Sendable>: Encodable, Sendable {
    let wrapped: Wrapped
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrapped)
    }
}

private enum Switch: Int, Codable, Sendable {
    case off = 0
    case on = 1
}

private struct Payload: Codable, Equatable, Sendable {
    let on: Bool
    let one: Int
    let zero: Int
    let label: String
}

/// Fails every decode with a recognisable reason, so a test can tell WHICH error reached the caller.
private struct Picky: Decodable {
    init(from decoder: any Decoder) throws {
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "picky-sentinel"))
    }
}

// MARK: - DuckDBBindEncoderTests

@Suite("DuckDBBindEncoder — a JSON boolean stays a bool and JSON 0/1 stay ints, on every platform")
struct DuckDBBindEncoderTests {
    @Test("a JSON boolean binds as a bool")
    func booleanStaysBool() throws {
        #expect(try DuckDBBindEncoder.encode(Bare(wrapped: true)) == .bool(true))
        #expect(try DuckDBBindEncoder.encode(Bare(wrapped: false)) == .bool(false))
    }

    @Test("JSON 0 and 1 bind as ints, never as bools")
    func zeroAndOneStayInts() throws {
        #expect(try DuckDBBindEncoder.encode(Bare(wrapped: 0)) == .int(0))
        #expect(try DuckDBBindEncoder.encode(Bare(wrapped: 1)) == .int(1))
        #expect(try DuckDBBindEncoder.encode(Switch.off) == .int(0))
        #expect(try DuckDBBindEncoder.encode(Switch.on) == .int(1))
    }

    @Test("numbers keep their kind: Int64 range as int, fractions as double")
    func numbersKeepTheirKind() throws {
        #expect(try DuckDBBindEncoder.encode(Bare(wrapped: Int64.max)) == .int(Int64.max))
        #expect(try DuckDBBindEncoder.encode(Bare(wrapped: Int64.min)) == .int(Int64.min))
        #expect(try DuckDBBindEncoder.encode(Bare(wrapped: 1.5)) == .double(1.5))
        #expect(try DuckDBBindEncoder.encode(Bare(wrapped: -0.25)) == .double(-0.25))
    }

    @Test("a string fragment keeps quotes, backslashes, newlines and non-ASCII exactly")
    func stringFragmentIsExact() throws {
        let text = "a \"quoted\" \\ back\nslash é 🦆 /"
        #expect(try DuckDBBindEncoder.encode(Bare(wrapped: text)) == .string(text))
    }

    @Test("an object binds as key-sorted JSON text whose booleans and 0/1 are still bools and ints")
    func objectBindsAsSortedJSONText() throws {
        let bound = try DuckDBBindEncoder.encode(Payload(on: true, one: 1, zero: 0, label: "x"))
        #expect(bound == .string(#"{"label":"x","on":true,"one":1,"zero":0}"#))
    }

    @Test("an array binds as JSON text")
    func arrayBindsAsJSONText() throws {
        #expect(try DuckDBBindEncoder.encode(Bare(wrapped: [true, false])) == .string("[true,false]"))
        #expect(try DuckDBBindEncoder.encode(Bare(wrapped: [0, 1])) == .string("[0,1]"))
    }

    @Test("an unrecognisable token is refused with an error, not bound as something else")
    func unrecognisableTokenThrows() {
        #expect(throws: DuckDBSQLError.self) { try DuckDBBindEncoder.bound(token: Data("not-json".utf8), of: String.self) }
        #expect(throws: DuckDBSQLError.self) { try DuckDBBindEncoder.bound(token: Data(), of: String.self) }
        #expect(throws: DuckDBSQLError.self) { try DuckDBBindEncoder.bound(token: Data("truex".utf8), of: String.self) }
        #expect(throws: DuckDBSQLError.self) { try DuckDBBindEncoder.bound(token: Data("fals".utf8), of: String.self) }
    }
}

// MARK: - DuckDBValueDecoderTests

@Suite("DuckDBValueDecoder — a value that fits no representation says why")
struct DuckDBValueDecoderTests {
    private func mismatch(_ work: () throws -> Void) -> String? {
        do {
            try work()
            return nil
        } catch DuckDBSQLError.typeMismatch(let message) {
            return message
        } catch {
            Issue.record("expected DuckDBSQLError.typeMismatch, got \(error)")
            return nil
        }
    }

    @Test("the final typeMismatch carries the probe's own decode error as its cause")
    func finalErrorCarriesTheProbeCause() {
        let message = mismatch { _ = try DuckDBValueDecoder.decode(Picky.self, from: .int(7)) }
        #expect(message?.contains("picky-sentinel") == true, "cause missing from: \(message ?? "no error")")
        #expect(message?.contains("JSON-fragment probe failed") == true)
        #expect(message?.contains("Picky") == true, "target type missing from: \(message ?? "no error")")
    }

    @Test("a cell with no JSON-fragment form says so instead of failing bare")
    func noFragmentFormIsNamed() {
        let message = mismatch { _ = try DuckDBValueDecoder.decode(Payload.self, from: .date(Date(timeIntervalSince1970: 0))) }
        #expect(message?.contains("no JSON-fragment form") == true, "reason missing from: \(message ?? "no error")")
    }

    @Test("a cell whose fragment decodes into the wrong shape reports where it went wrong")
    func wrongShapeReportsTheCodingPath() {
        let message = mismatch { _ = try DuckDBValueDecoder.decode(Payload.self, from: .bool(true)) }
        #expect(message?.contains("JSON-fragment probe failed") == true)
        #expect(message?.contains("(at v)") == true, "coding path missing from: \(message ?? "no error")")
    }

    @Test("a non-finite double is refused, not turned into null")
    func nonFiniteDoubleThrows() {
        for value in [Double.nan, .infinity, -.infinity] {
            let message = mismatch { _ = try DuckDBValueDecoder.decode(Double?.self, from: .double(value)) }
            #expect(message?.contains("non-finite") == true, "no refusal for \(value)")
        }
    }

    @Test("a finite double still decodes through an optional")
    func finiteDoubleDecodesThroughOptional() throws {
        #expect(try DuckDBValueDecoder.decode(Double?.self, from: .double(2.5)) == 2.5)
        #expect(try DuckDBValueDecoder.decode(Double?.self, from: .null) == nil)
    }

    @Test("JSON text stored in a string cell still decodes, and its own error propagates when it is not JSON")
    func jsonTextDecodeAndItsError() throws {
        let decoded = try DuckDBValueDecoder.decode(Payload.self, from: .string(#"{"on":true,"one":1,"zero":0,"label":"x"}"#))
        #expect(decoded == Payload(on: true, one: 1, zero: 0, label: "x"))
        #expect(throws: DecodingError.self) { try DuckDBValueDecoder.decode(Payload.self, from: .string("{bad")) }
    }

    @Test("a bool and an int cell decode through a RawRepresentable wrapper")
    func rawRepresentableDecodes() throws {
        #expect(try DuckDBValueDecoder.decode(Switch.self, from: .int(1)) == .on)
        #expect(try DuckDBValueDecoder.decode(Switch.self, from: .int(0)) == .off)
    }
}
#endif
