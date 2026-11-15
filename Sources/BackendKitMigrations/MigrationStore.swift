// MOVED — originally Sources/ShikkiPluginAPI/Migrations/MigrationStore.swift in shikki-plugin-api v0.15.0
// (commit 5d5c039b), also mirrored verbatim as KagamiMigrationCore. Everything below this block is
// that file, unchanged: same type names, same behaviour.
//
// BackendKitMigrations is the public, Foundation-only home of the engine-agnostic migration core
// (BR-MIG-11, operator decision 2026-11-08). It declares no dependency, so a consumer that links it
// (kagami, shikki-plugin-api) pulls no NIO, Postgres, SQLite or DuckDB into its build. The SQL
// adapters live beside their engines: `SQLMigrationStore` in BackendKitSQL.

// MigrationStore.swift — the one protocol every migration adapter conforms to.
//
// Spec: one-migration-runner-one-ledger-2026-10-01 (c8b11718) W5, BR-MIG-11
// (the protocol lives in the engine-agnostic kit) and BR-MIG-12 (adapters
// stay beside their driver and conform to one protocol):
// "`MigrationStore` (read applied set, apply one file transactionally, report
// `applied/gained/lost`): `BackendKitPostgres.PostgresMigrationStore` over
// postgres-nio (ShikkiMCP + shikki), libsql in DataKit, SQLite in shi-qa.
// `DataKit.MigrationRunner`'s 'every error is already-applied' and
// `;`-splitting are deleted by adoption, not fixed in place."
//
// Zero deps. Every adapter imports ShikkiPluginAPI, declares its driver, and
// is interchangeable from the host's perspective.

import Foundation

/// What one applied migration changed in the ledger.
///
/// `gained` and `lost` carry the identity delta (BR-MIG-08). A no-op apply —
/// the migration was already recorded — has `applied == false`,
/// `gained.isEmpty`, `lost.isEmpty`.
public struct MigrationApplyOutcome: Sendable, Equatable {
    /// The ledger version this file is responsible for (the filename stem).
    public let version: String
    /// `true` when the file ran against the server, `false` when the ledger
    /// already carried its version and nothing was executed.
    public let applied: Bool
    /// Rows the apply added to `schema_migrations`, by name.
    public let gained: [String]
    /// Rows the apply removed from `schema_migrations`, by name — a
    /// reconciliation (`@ledger-registers:`) retires a pre-canonical row.
    public let lost: [String]

    public init(version: String, applied: Bool, gained: [String], lost: [String]) {
        self.version = version
        self.applied = applied
        self.gained = gained
        self.lost = lost
    }

    /// The no-op shape: the version was already in the ledger.
    public static func noop(version: String) -> MigrationApplyOutcome {
        MigrationApplyOutcome(version: version, applied: false, gained: [], lost: [])
    }
}

/// Why an apply refused to run or failed mid-flight.
///
/// A common error type so the host can respond the same way across every
/// engine. Driver-specific detail travels in `underlying`.
public enum MigrationApplyError: Error, CustomStringConvertible {
    /// The file's declared identity (BR-MIG-04) does not match its filename,
    /// or it branches on the ledger, assembles a version literal, etc.
    /// `MigrationLedger.verify` throws the specific `Violation`; the adapter
    /// wraps it here so the host sees one error type across engines.
    case ledgerViolation(file: String, violation: MigrationLedger.Violation)
    /// The driver reported a failure. The transaction MUST have rolled back
    /// (BR-MIG-10) before this is thrown.
    case driverFailed(file: String, underlying: any Error)
    /// The ledger could not be read after an apply — the kind of defect a
    /// `try/catch` around only the DDL would hide.
    case ledgerUnreadable(file: String, underlying: any Error)

    public var description: String {
        switch self {
        case .ledgerViolation(let file, let violation):
            return "ledger violation in \(file): \(violation)"
        case .driverFailed(let file, let underlying):
            return "driver failed applying \(file): \(underlying)"
        case .ledgerUnreadable(let file, let underlying):
            return "ledger unreadable after \(file): \(underlying)"
        }
    }
}

/// The one protocol every migration adapter conforms to.
///
/// Three jobs:
///   1. `appliedMigrationVersions()` — read the ledger by identity.
///   2. `applyMigration(at:)` — apply one file transactionally, verifying
///      its ledger declaration before any SQL reaches the server.
///   3. `missing(from:)` — convenience over `MigrationLedgerContract.missing`.
///
/// The protocol says nothing about transports, pools or drivers; that is
/// the adapter's business. A host or plugin types against this and
/// swaps adapters at compile time.
public protocol MigrationStore: Sendable {
    /// The versions `schema_migrations` currently holds, as a set — identity,
    /// never a count (BR-MIG-08).
    func appliedMigrationVersions() async throws -> Set<String>

    /// Apply one `.sql` file to the server in one guarded transaction
    /// (BR-MIG-10). Verifies the file against `MigrationLedger` first; any
    /// throw after `BEGIN` rolls back; the outcome names what the ledger
    /// gained and lost (BR-MIG-12).
    @discardableResult
    func applyMigration(at url: URL) async throws -> MigrationApplyOutcome
}

extension MigrationStore {
    /// Shipped versions this store does not hold. Identity, in migration
    /// order (BR-MIG-08).
    public func missing(from shipped: [MigrationVersion]) async throws -> [String] {
        let applied = try await appliedMigrationVersions()
        return MigrationLedgerContract.missing(shipped: shipped, applied: applied)
    }
}
