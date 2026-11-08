import CoreKit
import Foundation
import SQLKit

// MARK: - SQLCacheBackingSchema

/// The one table a ``SQLCacheBacking`` stores into, keyed `(bucket, node, entry)`.
///
/// The column types are the ones every engine reads the same way: `TEXT`, `BLOB`
/// and a 64-bit integer. SQLKit renders the 64-bit integer as `BIGINT` on Postgres
/// and DuckDB and as `INTEGER` on SQLite, and `BLOB` as `BYTEA` on Postgres, so
/// the declaration below is the same text of code on all three, and legal in a
/// SQLite `STRICT` table.
///
/// Creating the table is the consumer's explicit step (BR-SQL-05), never a side
/// effect of using the backing: on SQLite through `SQLiteSQLHost.createStrictTable`,
/// anywhere else through ``create(on:table:)``.
public enum SQLCacheBackingSchema {

    /// The columns of the table.
    public enum Column: String, CaseIterable, Sendable {
        case bucket
        case node
        case entry
        case payload
        /// When the payload was last written: milliseconds since the Unix epoch.
        case modified
    }

    /// The table definition: five `NOT NULL` columns and the composite primary key.
    /// Pass it to `SQLiteSQLHost.createStrictTable(_:_:)` or to ``create(on:table:)``.
    public static func configure(_ builder: SQLCreateTableBuilder) -> SQLCreateTableBuilder {
        builder
            .column(Column.bucket.rawValue, type: .text, .notNull)
            .column(Column.node.rawValue, type: .text, .notNull)
            .column(Column.entry.rawValue, type: .text, .notNull)
            .column(Column.payload.rawValue, type: .blob, .notNull)
            .column(Column.modified.rawValue, type: .bigint, .notNull)
            .primaryKey(Column.bucket.rawValue, Column.node.rawValue, Column.entry.rawValue)
    }

    /// `CREATE TABLE IF NOT EXISTS` for Postgres and DuckDB.
    public static func create(on database: any SQLDatabase, table: String) async throws {
        try await configure(database.create(table: table).ifNotExists()).run()
    }
}

// MARK: - SQLCacheBacking

/// CoreKit's ``CacheBacking`` over a database table (spec d3f8a1b2, BR-RP-11, W4).
///
/// An entry is one row, addressed `(bucket, node, entry)` exactly like an object
/// in ``ObjectStoreCacheBacking``: the same cache code, the same bucket and node,
/// lands in a table or in an object store without the consumer changing. Three
/// nodes writing the same entry name write three rows. The backing is scoped to
/// one bucket and one node; ``scoped(to:)`` is how a consolidation step reads
/// another node's rows.
///
/// Built directly on SQLKit rather than on ``SQLRepository``: the contract needs
/// a listing scoped to a bucket and node that does not read every payload, an
/// existence check that does not read one, and a delete that answers whether
/// there was a row, and `SQLRepository` offers none of the three. Everything a
/// caller supplies (bucket, node, entry, bytes, time) is a bound parameter; the
/// only identifiers in the SQL are the table and ``SQLCacheBackingSchema/Column``
/// names, which SQLKit quotes. A value type: the engine behind `database` owns
/// its own concurrency, so concurrent callers need no lock here.
///
/// An entry that is absent is `nil` / `false`. Every engine error, a malformed
/// column included, is thrown with its cause, never replaced by a default.
public struct SQLCacheBacking: CacheBacking {

    private typealias Column = SQLCacheBackingSchema.Column

    public let bucket: BucketName
    public let node: NodeID

    private let database: any SQLDatabase
    private let table: String
    private let clock: @Sendable () -> Date

    /// - Parameters:
    ///   - database: the injected engine (`host.database` of any BackendKit host).
    ///   - table: a table created from ``SQLCacheBackingSchema``.
    ///   - clock: where the modified time of a write comes from.
    public init(
        database: any SQLDatabase,
        table: String,
        bucket: BucketName,
        node: NodeID,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.table = table
        self.bucket = bucket
        self.node = node
        self.clock = clock
    }

    /// The same table and bucket seen as another node.
    public func scoped(to node: NodeID) -> SQLCacheBacking {
        SQLCacheBacking(database: database, table: table, bucket: bucket, node: node, clock: clock)
    }

    // MARK: CacheBacking

    public func fetch(_ entry: String) async throws -> CacheBlob? {
        try validate(entry)
        let rows = try await select(Column.payload, Column.modified, entry: entry).limit(1).all()
        guard let row = rows.first else { return nil }
        let data = try row.decode(column: Column.payload.rawValue, as: Data.self)
        let milliseconds = try row.decode(column: Column.modified.rawValue, as: Int64.self)
        return CacheBlob(data: data, modified: Self.date(milliseconds: milliseconds))
    }

    public func put(_ data: Data, as entry: String) async throws {
        try validate(entry)
        // One statement, so a reader sees the old row or the new one, never half of a write.
        try await database.insert(into: table)
            .columns(Column.allCases.map(\.rawValue))
            .values(
                SQLBind(bucket.rawValue), SQLBind(node.description), SQLBind(entry), SQLBind(data),
                SQLBind(Self.milliseconds(of: clock()))
            )
            .onConflict(with: [Column.bucket, Column.node, Column.entry].map(\.rawValue)) { conflict in
                conflict
                    .set(excludedValueOf: Column.payload.rawValue)
                    .set(excludedValueOf: Column.modified.rawValue)
            }
            .run()
    }

    public func delete(_ entry: String) async throws -> Bool {
        try validate(entry)
        let builder = database.delete(from: table)
        let removed = try await scope(builder, entry: entry).returning(SQLIdentifier(Column.entry.rawValue)).all()
        return !removed.isEmpty
    }

    public func has(_ entry: String) async throws -> Bool {
        try validate(entry)
        let rows = try await select(Column.entry, entry: entry).limit(1).all()
        return !rows.isEmpty
    }

    public func entries() async throws -> [String] {
        let rows = try await database.select()
            .column(Column.entry.rawValue)
            .from(table)
            .where(Column.bucket.rawValue, .equal, bucket.rawValue)
            .where(Column.node.rawValue, .equal, node.description)
            .all()
        return try rows.map { try $0.decode(column: Column.entry.rawValue, as: String.self) }
    }

    // MARK: Helpers

    /// The empty name addresses no entry (an object store refuses it the same way); every other
    /// string is a legal key, since a bound parameter cannot climb out of anything.
    private func validate(_ entry: String) throws {
        guard !entry.isEmpty else {
            throw CacheBackingError.invalidEntryName(entry: entry, reason: "an entry name cannot be empty")
        }
    }

    private func select(_ columns: Column..., entry: String) -> SQLSelectBuilder {
        let select = database.select()
        for column in columns { select.column(column.rawValue) }
        return scope(select.from(table), entry: entry)
    }

    /// `WHERE bucket = ? AND node = ? AND entry = ?`, all three bound.
    private func scope<Builder: SQLPredicateBuilder>(_ builder: Builder, entry: String) -> Builder {
        builder
            .where(Column.bucket.rawValue, .equal, bucket.rawValue)
            .where(Column.node.rawValue, .equal, node.description)
            .where(Column.entry.rawValue, .equal, entry)
    }

    static func milliseconds(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
