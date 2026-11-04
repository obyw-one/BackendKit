import CoreKit
import Foundation
import SQLKit

// MARK: - SQLRepositoryError

public enum SQLRepositoryError: Error, Sendable, CustomStringConvertible {
    case notFound(idDescription: String)

    public var description: String {
        switch self {
        case .notFound(let id): "SQLRepositoryError.notFound(id: \(id))"
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
// Migration is the consumer's job (BackendKit's `MigrationRunner`, BR-SQL-05).

public actor SQLRepository<ID: Codable & Hashable & Sendable, Model: Codable & Sendable>: RepositoryProtocol {
    public typealias ModelType = Model

    private let database: any SQLDatabase
    private let table: String
    private let idColumn: String

    /// - Parameters:
    ///   - database: the injected engine (`SQLDatabase` from a driver host).
    ///   - table: the table this repository owns (quoted as an identifier).
    ///   - idColumn: the primary-key column. Default `"id"`. It must be one of
    ///     the Model's coding keys, so the upsert and the lookup agree.
    public init(database: any SQLDatabase, table: String, idColumn: String = "id") {
        self.database = database
        self.table = table
        self.idColumn = idColumn
    }

    // MARK: RepositoryProtocol

    public func get(_ id: ID) async throws -> Model {
        let rows = try await database.select()
            .column("*")
            .from(table)
            .where(SQLIdentifier(idColumn), .equal, SQLBind(id))
            .limit(1)
            .all()
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

    public func save(_ id: ID, data: Model) async throws {
        // `data` carries the id as one of its own columns; `id` is the key the
        // caller addresses it by. The conflict target is that column.
        try await database.insert(into: table)
            .model(data)
            .onConflict(with: idColumn) { try $0.set(excludedContentOf: data) }
            .run()
    }

    public func delete(_ id: ID) async throws {
        let rows = try await database.delete(from: table)
            .where(SQLIdentifier(idColumn), .equal, SQLBind(id))
            .returning(SQLIdentifier(idColumn))
            .all()
        if rows.isEmpty {
            throw SQLRepositoryError.notFound(idDescription: String(describing: id))
        }
    }
}
