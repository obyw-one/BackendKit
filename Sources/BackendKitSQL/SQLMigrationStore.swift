import BackendKitMigrations
import Foundation
import SQLKit

// MARK: - SQLMigrationLedger

/// The ledger table a ``SQLMigrationStore`` keeps, in a shape every engine accepts.
///
/// `BackendKitMigrations`' `MigrationLedgerContract.createTableSQL` is Postgres-only
/// (`applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`: SQLite refuses `DEFAULT <call>`, and a
/// SQLite `STRICT` table has no `TIMESTAMPTZ`). This definition keeps what every reader depends on,
/// the table name and the `version TEXT PRIMARY KEY` / `applied_at` columns in that order, so
/// `contract.selectAllVersionsSQL` runs against it unchanged, and takes the timestamp default from
/// the one expression all three engines share: `CURRENT_TIMESTAMP`, held as text.
public enum SQLMigrationLedger {

    public enum Column: String, CaseIterable, Sendable {
        case version
        case appliedAt = "applied_at"
    }

    /// The table definition; pass it to `SQLiteSQLHost.createStrictTable(_:_:)` or ``create(on:contract:)``.
    public static func configure(_ builder: SQLCreateTableBuilder) -> SQLCreateTableBuilder {
        // `CURRENT_TIMESTAMP` is a keyword, not a call: valid, and the same, on every engine.
        let now: any SQLExpression = SQLRaw("CURRENT_TIMESTAMP")
        return builder
            .column(Column.version.rawValue, type: .text, .primaryKey(autoIncrement: false), .notNull)
            .column(Column.appliedAt.rawValue, type: .text, .notNull, SQLColumnConstraintAlgorithm.default(now))
    }

    /// `CREATE TABLE IF NOT EXISTS` for Postgres and DuckDB.
    public static func create(on database: any SQLDatabase, contract: MigrationLedgerContract = MigrationLedgerContract()) async throws {
        try await configure(database.create(table: contract.tableName).ifNotExists()).run()
    }
}

// MARK: - SQLMigrationStoreError

/// A failure of the store's own mechanics, as distinct from ``MigrationApplyError``
/// (a file refused or a statement that failed).
public enum SQLMigrationStoreError: Error, Sendable, CustomStringConvertible {
    /// A statement failed and the `ROLLBACK` that followed failed too: the connection may still be inside a
    /// transaction. Both causes are carried; neither is dropped.
    case rollbackFailed(statementError: String, rollbackError: String)
    /// The file could not be read.
    case fileUnreadable(path: String, cause: String)

    public var description: String {
        switch self {
        case .rollbackFailed(let statementError, let rollbackError):
            "SQLMigrationStore: \(statementError); the ROLLBACK then failed too (\(rollbackError)), so the connection may still hold an open transaction"
        case .fileUnreadable(let path, let cause):
            "SQLMigrationStore: migration file unreadable at \(path) — \(cause)"
        }
    }
}

// MARK: - SQLMigrationStore

/// The SQL adapter of `BackendKitMigrations`' ``MigrationStore`` (BR-MIG-12, BR-SQL-05): one
/// implementation over SQLKit for SQLite, DuckDB and Postgres.
///
/// - The ledger is read through the typed builder; its table is created explicitly by the consumer
///   from ``SQLMigrationLedger`` (STRICT on SQLite), never as a side effect of reading.
/// - A file is verified against `MigrationLedger` BEFORE any statement reaches the engine, split by
///   the core (`$tag$` bodies kept whole, the file's own `BEGIN`/`COMMIT` dropped), and run in ONE
///   transaction on ONE connection (`withSession`: a pooled Postgres would otherwise send `BEGIN` and the
///   statements down different connections). Any throw after `BEGIN` rolls back, and a failed `ROLLBACK`
///   is thrown together with the failure that caused it (BR-MIG-10).
/// - The migration's own SQL is the one thing executed as text: it is the file's content, verified, with no
///   caller value in it. No value is ever concatenated into a statement this type writes itself.
/// - The ledger row is the FILE's job (`MigrationLedger.verify` refuses one that does not register itself),
///   so `gained`/`lost` are the delta the file's own statements produced.
///
/// An actor: two applies on one store never interleave. DuckDB has one connection, so nothing else may use
/// that database while a migration runs; migrations are a startup step.
public actor SQLMigrationStore: MigrationStore {

    nonisolated public let contract: MigrationLedgerContract
    private let database: any SQLDatabase

    /// - Parameters:
    ///   - database: the injected engine (`host.database` of any BackendKit host).
    ///   - contract: the ledger table's name (default `schema_migrations`). SQLKit quotes identifiers per
    ///     dialect, so the contract's `identifierQuote` is not used here. Keep the default for migration FILES:
    ///     the kit's ledger rules (`MigrationLedger.verify`) read the literal `schema_migrations` in them.
    public init(database: any SQLDatabase, contract: MigrationLedgerContract = MigrationLedgerContract()) {
        self.database = database
        self.contract = contract
    }

    // MARK: MigrationStore

    public func appliedMigrationVersions() async throws -> Set<String> {
        try await Self.readVersions(database, contract: contract)
    }

    @discardableResult
    public func applyMigration(at url: URL) async throws -> MigrationApplyOutcome {
        let fileName = url.lastPathComponent
        let version = MigrationLedger.version(ofFileNamed: fileName)

        let sql: String
        do {
            sql = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw SQLMigrationStoreError.fileUnreadable(path: url.path, cause: "\(error)")
        }

        do {
            try MigrationLedger.verify(fileNamed: fileName, sql: sql)
        } catch let violation as MigrationLedger.Violation {
            throw MigrationApplyError.ledgerViolation(file: fileName, violation: violation)
        }

        let before: Set<String>
        do {
            before = try await Self.readVersions(database, contract: contract)
        } catch {
            throw MigrationApplyError.ledgerUnreadable(file: fileName, underlying: error)
        }
        guard !before.contains(version) else { return .noop(version: version) }

        let statements = MigrationLedger.applicableStatements(sql)
        do {
            try await database.withSession { session in
                try await Self.runTransaction(statements, on: session)
            }
        } catch {
            throw MigrationApplyError.driverFailed(file: fileName, underlying: error)
        }

        let after: Set<String>
        do {
            after = try await Self.readVersions(database, contract: contract)
        } catch {
            // The statements committed but the ledger cannot be read: a defect a catch around only the DDL would hide.
            throw MigrationApplyError.ledgerUnreadable(file: fileName, underlying: error)
        }
        return MigrationApplyOutcome(
            version: version, applied: true, gained: after.subtracting(before).sorted(), lost: before.subtracting(after).sorted())
    }

    /// Applies every migration in `directory` in numeric order, skipping those the ledger already holds.
    /// Running it twice is the idempotence the ledger exists for: the second run is all no-ops.
    /// - Throws: ``MigrationManifestError`` for a directory that cannot be read, and whatever
    ///   ``applyMigration(at:)`` throws for the first file that fails (later files are not attempted).
    @discardableResult
    public func applyAll(in directory: URL) async throws -> [MigrationApplyOutcome] {
        var outcomes: [MigrationApplyOutcome] = []
        for version in try MigrationManifest.versions(in: directory) {
            outcomes.append(try await applyMigration(at: directory.appendingPathComponent(version.fileName)))
        }
        return outcomes
    }

    // MARK: Internals

    private static func readVersions(_ database: any SQLDatabase, contract: MigrationLedgerContract) async throws -> Set<String> {
        let rows = try await database.select()
            .column(SQLMigrationLedger.Column.version.rawValue)
            .from(contract.tableName)
            .all()
        return Set(try rows.map { try $0.decode(column: SQLMigrationLedger.Column.version.rawValue, as: String.self) })
    }

    /// BEGIN, every statement, COMMIT: one do/catch, so a throw from any of them, COMMIT included, rolls back.
    private static func runTransaction(_ statements: [String], on session: any SQLDatabase) async throws {
        try await session.raw("BEGIN").run()
        do {
            for statement in statements {
                try await session.raw("\(unsafeRaw: statement)").run()
            }
            try await session.raw("COMMIT").run()
        } catch {
            do {
                try await session.raw("ROLLBACK").run()
            } catch let rollbackError {
                throw SQLMigrationStoreError.rollbackFailed(statementError: "\(error)", rollbackError: "\(rollbackError)")
            }
            throw error
        }
    }
}
