import BackendKitDuckDB
import BackendKitSQL
import Foundation
import SQLKit
import Testing

// MARK: - DuckDBRepositoryTypesTests

//
// The public path end to end, with every Swift type a model can carry: `SQLRepository` over `DuckDBSQLHost`, a Codable
// model saved, read back, listed, replaced and deleted. Only public API is used, so this is what a consumer sees, and
// it is compiled unchanged on every platform. SQLKit hands a model's Decimal, Date and Data fields to the driver
// wrapped in its `FakeSendableCodable`; this test is what caught the driver binding them as Doubles.

struct Everything: Codable, Equatable, Sendable {
    let id: UUID
    let flag: Bool
    let small: Int
    let big: Int64
    let unsigned: UInt32
    let ratio: Double
    let price: Decimal
    let name: String
    let payload: Data
    let moment: Date
    let note: String?
    let discount: Decimal?
}

@Suite("SQLRepository over DuckDB — every Swift type round-trips")
struct DuckDBRepositoryTypesTests {
    private static let table = """
        CREATE TABLE everything (
            id UUID PRIMARY KEY, flag BOOLEAN NOT NULL, small BIGINT NOT NULL, big BIGINT NOT NULL, unsigned UINTEGER NOT NULL,
            ratio DOUBLE NOT NULL, price DECIMAL(38,6) NOT NULL, name VARCHAR NOT NULL, payload BLOB NOT NULL, moment TIMESTAMP NOT NULL,
            note VARCHAR, discount DECIMAL(38,6)
        )
        """

    private static func sample(_ index: Int, note: String? = nil, discount: Decimal? = nil) -> Everything {
        Everything(
            id: UUID(),
            flag: index.isMultiple(of: 2),
            small: index - 3,
            big: Int64.max - Int64(index),
            unsigned: UInt32.max - UInt32(index),
            ratio: Double(index) / 8,
            price: Decimal(string: "\(index * 1000).123456")!,
            name: "name \(index) é🦆",
            payload: Data([0, UInt8(index), 255]),
            moment: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) + 0.25),
            note: note,
            discount: discount
        )
    }

    @Test("save, get, list, update and delete with decimals, UUIDs, blobs, dates and NULLs")
    func roundTrip() async throws {
        let host = try await DuckDBSQLHost.open(storage: .memory)
        do {
            try await host.database.raw(SQLQueryString(Self.table)).run()
            let repo = SQLRepository<UUID, Everything>(database: host.database, table: "everything")
            let first = Self.sample(1)
            let second = Self.sample(2, note: "has a note", discount: Decimal(string: "12345678901234567890123456.123456"))
            let third = Self.sample(3, discount: 0)
            for item in [first, second, third] { try await repo.save(item.id, data: item) }

            #expect(try await repo.get(first.id) == first)
            #expect(try await repo.get(second.id) == second)
            #expect(try await repo.get(third.id) == third)
            #expect(try await repo.list().count == 3)

            let changed = Everything(
                id: first.id, flag: !first.flag, small: first.small, big: first.big, unsigned: first.unsigned, ratio: first.ratio,
                price: Decimal(string: "100")!, name: first.name, payload: Data(), moment: first.moment, note: "now set", discount: nil
            )
            try await repo.save(first.id, data: changed)
            #expect(try await repo.get(first.id) == changed)

            try await repo.delete(second.id)
            #expect(try await repo.list().count == 2)
        } catch {
            try? await host.shutdown()
            throw error
        }
        try await host.shutdown()
    }

    @Test("typed rows decode through SQLKit: Decimal, UUID, Data, Date and optionals")
    func decodeColumns() async throws {
        let host = try await DuckDBSQLHost.open(storage: .memory)
        defer { Task { try? await host.shutdown() } }
        let rows = try await host.database.raw("""
            SELECT '12345678901234567890123456789012345678'::DECIMAL(38,0) AS d, 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::UUID AS u,
                   from_hex('00ff') AS b, TIMESTAMP '2026-11-07 12:34:56' AS t, DATE '2026-11-07' AS day, NULL::INTEGER AS missing,
                   '170141183460469231731687303715884105727'::HUGEINT AS huge, 42::UTINYINT AS tiny, 'x'::VARCHAR AS s
            """).all()
        let row = try #require(rows.first)
        #expect(try row.decode(column: "d", as: Decimal.self) == Decimal(string: "12345678901234567890123456789012345678"))
        #expect(try row.decode(column: "u", as: UUID.self) == UUID(uuidString: "A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11"))
        #expect(try row.decode(column: "b", as: Data.self) == Data([0, 255]))
        #expect(try row.decode(column: "t", as: Date.self) == Date(timeIntervalSince1970: 1_794_054_896))
        #expect(try row.decode(column: "day", as: Date.self) == Date(timeIntervalSince1970: 20764 * 86400))
        #expect(try row.decode(column: "missing", as: Int?.self) == nil)
        #expect(try row.decodeNil(column: "missing"))
        #expect(try row.decode(column: "huge", as: String.self) == "170141183460469231731687303715884105727")
        #expect(try row.decode(column: "tiny", as: UInt8.self) == 42)
        #expect(try row.decode(column: "s", as: String.self) == "x")
    }

    @Test("DuckDB's own error text reaches the caller of the public API")
    func publicErrors() async throws {
        let host = try await DuckDBSQLHost.open(storage: .memory)
        do {
            do {
                try await host.database.raw("SELECT * FROM table_that_does_not_exist").run()
                Issue.record("no error")
            } catch let error as DuckDBSQLError {
                guard case .engine(let message) = error else {
                    Issue.record("expected .engine, got \(error)")
                    return
                }
                #expect(message.contains("Catalog Error"))
                #expect(error.errorDescription == message)
            }
            try await host.shutdown()
            await #expect(throws: DuckDBSQLError.shutDown) { try await host.database.raw("SELECT 1").run() }
        } catch {
            try? await host.shutdown()
            throw error
        }
    }
}
