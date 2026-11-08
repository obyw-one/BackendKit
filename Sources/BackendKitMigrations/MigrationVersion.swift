// MOVED — originally Sources/ShikkiPluginAPI/Migrations/MigrationVersion.swift in shikki-plugin-api v0.15.0
// (commit 5d5c039b), also mirrored verbatim as KagamiMigrationCore. Everything below this block is
// that file, unchanged: same type names, same behaviour.
//
// BackendKitMigrations is the public, Foundation-only home of the engine-agnostic migration core
// (BR-MIG-11, operator decision 2026-11-08). It declares no dependency, so a consumer that links it
// (kagami, shikki-plugin-api) pulls no NIO, Postgres, SQLite or DuckDB into its build. The SQL
// adapters live beside their engines: `SQLMigrationStore` in BackendKitSQL.

// MigrationVersion.swift — one shipped migration, identified the way the ledger identifies it.
//
// Spec: one-migration-runner-one-ledger-2026-10-01 (c8b11718) W5, BR-MIG-11:
// "The engine-agnostic core lives in shikki-plugin-api. MigrationVersion […]
// Nothing in it imports a database driver."
//
// Extracted verbatim from `ShikkiMCPPostgresKit/MigrationManifest.swift` so a
// plugin — and every consumer of shikki's own `MigrationStore` — can type
// against the same identity ShikkiMCP ships against.

import Foundation

/// One shipped migration, identified the way the ledger identifies it.
///
/// `name` is the `schema_migrations.version` string a migration registers —
/// per BR-MIG-04 the filename IS that version, so `048_spec.sql` → `048_spec`.
public struct MigrationVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// Ledger version string — the filename without `.sql` (and without `.up`).
    public let name: String
    /// Leading digits parsed as an integer, so `048_spec` and `0040_nodes`
    /// compare by number instead of lexically. The ledger's own ordering is
    /// lexical today, which is why `0040_launch_requests` sorts between `003_`
    /// and `004_` there (spec §1.3).
    public let ordinal: Int
    /// The file this version was read from.
    public let fileName: String

    public init(name: String, ordinal: Int, fileName: String) {
        self.name = name
        self.ordinal = ordinal
        self.fileName = fileName
    }

    public var description: String { name }

    public static func < (lhs: MigrationVersion, rhs: MigrationVersion) -> Bool {
        lhs.ordinal == rhs.ordinal ? lhs.name < rhs.name : lhs.ordinal < rhs.ordinal
    }
}

/// Why reading a migrations directory failed.
public enum MigrationManifestError: Error, CustomStringConvertible, Equatable {
    /// A `.sql` file in the migrations directory carries no leading number, so
    /// it has no place in the sequence BR-MIG-03 requires.
    case unnumbered(fileName: String)
    /// The directory could not be read.
    case unreadable(path: String)

    public var description: String {
        switch self {
        case .unnumbered(let fileName):
            return
                "migration '\(fileName)' has no leading number — BR-MIG-03 requires a zero-padded, strictly increasing prefix"
        case .unreadable(let path):
            return "migrations directory unreadable at \(path)"
        }
    }
}
