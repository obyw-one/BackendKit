import CoreKit
import Foundation
import SQLKit

// MARK: - SQLRepositoryError

public enum SQLRepositoryError: Error, Sendable, CustomStringConvertible {
    case notFound(idDescription: String)
    /// A composite key whose encoded columns are not exactly the repository's `keyColumns`.
    case keyMismatch(expected: [String], actual: [String])

    /// `update(_:set:)` was given no column to change.
    case emptyPatch

    public var description: String {
        switch self {
        case .notFound(let id): "SQLRepositoryError.notFound(id: \(id))"
        case .emptyPatch: "SQLRepositoryError.emptyPatch"
        case .keyMismatch(let expected, let actual): "SQLRepositoryError.keyMismatch(expected: \(expected), actual: \(actual))"
        }
    }
}

// MARK: - SQLRepository

//
// A CoreKit `RepositoryProtocol` over one table, built on SQLKit's builder
// (spec b4f8c3a1, BR-SQL-01/02/04/07). The Model's Codable keys are the
// columns; every value (ids included) is a bound parameter and rows decode
// straight into the Model. The only strings that reach SQL as identifiers are
// the table and column names, which SQLKit quotes via `SQLIdentifier`.
//
// The engine is the injected `SQLDatabase`. SQLKit's NIO-future surface is
// consumed ONLY through SQLKit's own async builder methods here: nothing
// public on this type exposes an EventLoopFuture (BR-SQL-07).
//
// Migration is the consumer's job: `SQLMigrationStore` (this target) applies a migrations folder through the ledger (BR-SQL-05).

public actor SQLRepository<ID: Codable & Hashable & Sendable, Model: Codable & Sendable>: RepositoryProtocol {
    public typealias ModelType = Model

    private let database: any SQLDatabase
    private let table: String
    private let keyColumns: [String]

    /// - Parameters:
    ///   - database: the injected engine (`SQLDatabase` from a driver host).
    ///   - table: the table this repository owns (quoted as an identifier).
    ///   - idColumn: the primary-key column. Default `"id"`. It must be one of
    ///     the Model's coding keys, so the upsert and the lookup agree.
    public init(database: any SQLDatabase, table: String, idColumn: String = "id") {
        self.init(database: database, table: table, keyColumns: [idColumn])
    }

    /// A table keyed by several columns (a composite primary key). `ID` is then a
    /// Codable value whose coding keys are exactly `keyColumns` (e.g. a
    /// `(providerId, modelId)` struct); every key value is still a bound parameter.
    /// With one key column `ID` is that column's value, as in the `idColumn:` form.
    public init(database: any SQLDatabase, table: String, keyColumns: [String]) {
        self.database = database
        self.table = table
        self.keyColumns = keyColumns
    }

    /// The bound `column = value` pairs that address `id`.
    private func keyPairs(_ id: ID) throws -> [(column: String, value: any SQLExpression)] {
        if keyColumns.count == 1 { return [(keyColumns[0], SQLBind(id))] }
        let encoded = try SQLQueryEncoder().encode(id)
        let actual = encoded.map(\.0)
        guard Set(actual) == Set(keyColumns), actual.count == keyColumns.count else {
            throw SQLRepositoryError.keyMismatch(expected: keyColumns, actual: actual)
        }
        return encoded.map { (column: $0.0, value: $0.1) }
    }

    // MARK: RepositoryProtocol

    public func get(_ id: ID) async throws -> Model {
        let select = database.select().column("*").from(table)
        for pair in try keyPairs(id) {
            select.where(SQLIdentifier(pair.column), .equal, pair.value)
        }
        let rows = try await select.limit(1).all()
        guard let row = rows.first else {
            throw SQLRepositoryError.notFound(idDescription: String(describing: id))
        }
        return try row.decode(model: Model.self)
    }

    public func list() async throws -> [Model] {
        try await database.select()
            .column("*")
            .from(table)
            .all(decoding: Model.self)
    }

    /// PUT: a full-row REPLACE (BR-SQL-09). Every column is written, and a `nil` optional is an
    /// explicit SQL NULL (`nilEncodingStrategy: .asNil`; SQLKit's default OMITS nils, which made
    /// `save` silently patch). Saving a model whose field is nil therefore CLEARS that column on an
    /// existing row. For a partial change use `update(_:set:)`.
    public func save(_ id: ID, data: Model) async throws {
        // `data` carries the id as one of its own columns; `id` is the key the
        // caller addresses it by. The conflict target is that column.
        // The update side assigns every column EXCEPT the conflict key(s): assigning the key
        // is a no-op by definition, and DuckDB refuses it outright ("Can not assign to
        // column ... because it has a UNIQUE/PRIMARY KEY constraint").
        let updated = try SQLQueryEncoder(nilEncodingStrategy: .asNil).encode(data).map(\.0).filter { !keyColumns.contains($0) }
        try await database.insert(into: table)
            .model(data, nilEncodingStrategy: .asNil)
            .onConflict(with: keyColumns) { builder in
                updated.reduce(builder) { $0.set(excludedValueOf: $1) }
            }
            .run()
    }

    /// PATCH: only the named columns change (BR-SQL-09). A column mapped to `nil` is written as an
    /// explicit SQL NULL; a column not named is untouched. Scoped by every key column of `id`.
    /// Throws `notFound` when no row matches, and `emptyPatch` when `set` names no column.
    public func update(_ id: ID, set columns: [String: (any Encodable & Sendable)?]) async throws {
        guard !columns.isEmpty else { throw SQLRepositoryError.emptyPatch }
        let update = database.update(table)
        for name in columns.keys.sorted() {
            switch columns[name] {
            case .some(.some(let value)): update.set(name, to: value)
            default: update.set(name, to: SQLLiteral.null)
            }
        }
        for pair in try keyPairs(id) {
            update.where(SQLIdentifier(pair.column), .equal, pair.value)
        }
        let rows = try await update.returning(SQLIdentifier(keyColumns[0])).all()
        if rows.isEmpty {
            throw SQLRepositoryError.notFound(idDescription: String(describing: id))
        }
    }

    /// A plain insert: unlike `save` it never updates, so a row whose key (or any other UNIQUE
    /// column set) already exists is refused by the engine. The driver's error propagates
    /// untouched; an engine host classifies it (`SQLiteSQLHost.isConstraintViolation`).
    public func insert(_ data: Model) async throws {
        try await database.insert(into: table)
            .model(data)
            .run()
    }

    public func delete(_ id: ID) async throws {
        let delete = database.delete(from: table)
        for pair in try keyPairs(id) {
            delete.where(SQLIdentifier(pair.column), .equal, pair.value)
        }
        let rows = try await delete.returning(SQLIdentifier(keyColumns[0])).all()
        if rows.isEmpty {
            throw SQLRepositoryError.notFound(idDescription: String(describing: id))
        }
    }
}
