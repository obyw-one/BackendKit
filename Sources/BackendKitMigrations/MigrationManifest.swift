// MOVED — originally Sources/ShikkiPluginAPI/Migrations/MigrationManifest.swift in shikki-plugin-api v0.15.0
// (commit 5d5c039b), also mirrored verbatim as KagamiMigrationCore. Everything below this block is
// that file, unchanged: same type names, same behaviour.
//
// BackendKitMigrations is the public, Foundation-only home of the engine-agnostic migration core
// (BR-MIG-11, operator decision 2026-11-08). It declares no dependency, so a consumer that links it
// (kagami, shikki-plugin-api) pulls no NIO, Postgres, SQLite or DuckDB into its build. The SQL
// adapters live beside their engines: `SQLMigrationStore` in BackendKitSQL.

// MigrationManifest.swift — the shipped migration set, read from `migrations/`.
//
// Spec: one-migration-runner-one-ledger-2026-10-01 (c8b11718) W5, BR-MIG-11:
// "The engine-agnostic core lives in shikki-plugin-api. MigrationVersion,
// MigrationManifest (manifest/registry/snapshot) […]. Nothing in it imports a
// database driver."
//
// Extracted from `ShikkiMCPPostgresKit/MigrationManifest.swift`. Behavioural
// deltas from the ShikkiMCP copy:
//   · the kit does NOT ship migrations and so cannot type a snapshot of its
//     own — a caller passing a `snapshot:` becomes the floor used when a scan
//     fails. This is BR-MIG-11's "snapshot" seam.
//   · `inheritedLedgerRowCount` is deleted. The count was one database's row
//     total and no second database could ever satisfy it (panel e7061336,
//     Critical). The gate is identity-based: `missing(shipped:applied:)` on
//     `MigrationLedgerContract`.
//   · `expectedSchemaVersion` is deleted. BR-MIG-05: a hand-typed total
//     drifted three times. Derive from `MigrationManifest.Resolution.versions`
//     instead.
//   · the set is read from the consumer's RESOURCE BUNDLE and nowhere else
//     (review on shikki-io/shikki-plugin-api#21, 2026-10-23; BR-MIG-14). A
//     consumer declares `resources: [.copy("migrations")]` on its target, the
//     files ship inside the signed bundle next to its binary, and the kit asks
//     `Bundle.url(forResource:)`. No source-tree walk, no `#filePath`, no
//     working directory, no executable-relative search: an installed binary
//     and a test both answer from a bundle, so the shipped set can never be
//     read from whichever checkout the process happens to run in.

import Foundation

/// The shipped migration set and where it was read from.
public enum MigrationManifest: Sendable {

    // MARK: - Where the set came from

    /// How the resolved set came to be, so a caller can log a snapshot
    /// fallback instead of inheriting a silently wrong number.
    public enum Source: Sendable, Equatable {
        /// Read from a real directory on disk.
        case scanned(path: String)
        /// The directory could not be located or read; the caller's
        /// `snapshot:` stood in. `reason` is meant to be logged, not swallowed.
        case snapshot(reason: String)
    }

    /// The shipped set plus its provenance.
    public struct Resolution: Sendable {
        public let versions: [MigrationVersion]
        public let source: Source

        public init(versions: [MigrationVersion], source: Source) {
            self.versions = versions
            self.source = source
        }

        /// The shipped versions by name — what a database must contain to be
        /// current.
        public var shippedVersionNames: [String] { versions.map(\.name) }

        /// Shipped versions the ledger does not hold, in migration order.
        /// Empty = current.
        public func missing(applied: Set<String>) -> [String] {
            versions.filter { !applied.contains($0.name) }.map(\.name)
        }

        /// The `source` as one word for a health payload: `scanned` or
        /// `snapshot`.
        public var sourceLabel: String {
            switch source {
            case .scanned: return "scanned"
            case .snapshot: return "snapshot"
            }
        }

        /// Numbers used by more than one shipped file (BR-MIG-03 violation).
        /// Reported rather than thrown — the ratchet lives in the host.
        public var duplicateOrdinals: [Int] {
            Dictionary(grouping: versions, by: \.ordinal)
                .filter { $0.value.count > 1 }
                .keys
                .sorted()
        }
    }

    // MARK: - Reading the set

    /// Every migration in `directory`, ordered by number.
    ///
    /// `*.down.sql` files are rollbacks, not ledger entries, and are skipped.
    /// A `*.up.sql` file registers under its bare name, so `043_x.up.sql` →
    /// `043_x`.
    public static func versions(in directory: URL) throws -> [MigrationVersion] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw MigrationManifestError.unreadable(path: directory.path)
        }
        var found: [MigrationVersion] = []
        for fileName in names where fileName.hasSuffix(".sql") {
            if fileName.hasSuffix(".down.sql") { continue }
            var name = String(fileName.dropLast(".sql".count))
            if name.hasSuffix(".up") { name = String(name.dropLast(".up".count)) }
            let digits = name.prefix { $0.isNumber }
            guard !digits.isEmpty, let ordinal = Int(digits) else {
                throw MigrationManifestError.unnumbered(fileName: fileName)
            }
            found.append(MigrationVersion(name: name, ordinal: ordinal, fileName: fileName))
        }
        return found.sorted()
    }

    /// The default resource folder name every consumer ships: `migrations/`.
    public static let defaultResourceDirectoryName = "migrations"

    /// The shipped `migrations/` directory inside `bundle`, or `nil` when the
    /// bundle carries no such resource.
    ///
    /// The bundle is the consumer's (`Bundle.module` for a SwiftPM target that
    /// declares `resources: [.copy("migrations")]`, or the app bundle). It is
    /// the ONLY place the kit looks: the files travel with the signed binary
    /// (BR-MIG-14), so an installed server, a test and a plugin all answer from
    /// what was compiled in — never from a checkout the process runs inside.
    public static func migrationsDirectory(
        in bundle: Bundle,
        named directoryName: String = defaultResourceDirectoryName
    ) -> URL? {
        guard let url = bundle.url(forResource: directoryName, withExtension: nil) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url
    }

    /// The shipped set read from `bundle`, plus where it came from. Never
    /// throws: a bundle without the resource, or one that cannot be read,
    /// degrades to `snapshot` and says so in `Source`, so the caller logs the
    /// degradation instead of inheriting a silently wrong number.
    ///
    /// `snapshot` is the floor for a consumer whose bundle was built without
    /// the resource — passed by the consumer because this kit ships no
    /// migrations of its own. When the resource is present the scan always wins.
    public static func resolve(
        bundle: Bundle,
        directoryName: String = defaultResourceDirectoryName,
        snapshot: [MigrationVersion] = []
    ) -> Resolution {
        guard let directory = migrationsDirectory(in: bundle, named: directoryName) else {
            return Resolution(
                versions: snapshot,
                source: .snapshot(
                    reason:
                        "resource '\(directoryName)/' not found in bundle \(bundle.bundleURL.path) — "
                        + "declare `resources: [.copy(\"\(directoryName)\")]` on the target that ships the migrations"
                ))
        }
        do {
            return Resolution(
                versions: try versions(in: directory),
                source: .scanned(path: directory.path))
        } catch {
            return Resolution(versions: snapshot, source: .snapshot(reason: "\(error)"))
        }
    }
}
