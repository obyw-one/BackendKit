// MigrationManifestTests.swift — the engine-agnostic migration core, verified
// without a database.
//
// Spec: one-migration-runner-one-ledger-2026-10-01 (c8b11718) W5. These tests
// are "`MigrationManifestTests + MigrationLedgerTests` from ShikkiMCP, minus
// the Postgres apply" (spec Phase 5b, W5 Tests block).
//
// T-17 (installed-binary discovery): the shipped set is read from the
// consumer's RESOURCE BUNDLE (review on #21, BR-MIG-14) — here the kit has no
// `migrations/` of its own, so the tests plant a `.bundle` directory and open
// it with `Bundle(url:)`, exactly what `Bundle.module` is for a SwiftPM target
// that declares `resources: [.copy("migrations")]`.
// T-18 (the core imports no driver): `MigrationCoreIsFoundationOnlyTests` proves
// the target stays Foundation-only. MOVED from shikki-plugin-api's test target
// with the code it tests (operator decision 2026-11-08); the cases are unchanged.

import CoreKitTestSupport
import Foundation
import Testing

@testable import BackendKitMigrations

private let testPaths = MigrationTestPaths()

/// Scratch locations under the package's own `.tests/` (CoreKit `TestScratch`). A sandbox name is
/// unique and NOT created: a test that needs the directory creates it, and one that needs a missing
/// path gets one.
private struct MigrationTestPaths: Sendable {
    private let scratch = TestScratch.forPackage()

    func sandbox(_ label: String) -> URL {
        scratch.scratchRoot(scope: "migration-core").appendingPathComponent("\(label)-\(UUID().uuidString)")
    }

    func discard(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try scratch.removeScratchDir(url)
        } catch {
            Issue.record("could not remove the scratch directory \(url.path): \(error)")
        }
    }
}

@Suite("MigrationManifest (c8b11718 W5) — reads a directory, orders by number, degrades loudly")
struct MigrationManifestTests {

    // MARK: - Fixtures

    /// Write `names` as empty-ish `.sql` files into a fresh scratch directory.
    private func plant(_ names: [String], scope: String) throws -> URL {
        let dir = testPaths.sandbox("migrations-\(scope)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            try "-- fixture\n".write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    /// A resource bundle the way SwiftPM lays one out: `<name>.bundle/migrations/*.sql`.
    /// `migrations: nil` plants a bundle WITHOUT the resource.
    private func plantBundle(migrations names: [String]?, scope: String) throws -> Bundle {
        let root = testPaths.sandbox("bundle-\(scope)").appendingPathExtension("bundle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let names {
            let migrations = root.appendingPathComponent("migrations", isDirectory: true)
            try FileManager.default.createDirectory(at: migrations, withIntermediateDirectories: true)
            for name in names {
                try "-- fixture\n".write(
                    to: migrations.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
        guard let bundle = Bundle(url: root) else {
            throw MigrationManifestError.unreadable(path: root.path)
        }
        return bundle
    }

    private func cleanUp(_ url: URL) { testPaths.discard(url) }

    // MARK: - MigrationVersion ordering

    @Test("MigrationVersion sorts by ordinal, not lexically like the ledger")
    func versionsOrderByNumber() throws {
        // The ledger sorts lexically, which is why `0040_launch_requests`
        // sorts between `003_` and `004_` there (spec §1.3). The manifest
        // must not.
        let dir = try plant(
            ["0040_launch_requests.sql", "004_orchestrator.sql", "003_pipeline.sql"],
            scope: "manifest-ordering")
        defer { cleanUp(dir) }

        let shipped = try MigrationManifest.versions(in: dir)
        #expect(shipped.map(\.ordinal) == [3, 4, 40])
        #expect(
            shipped.map(\.name) == ["003_pipeline", "004_orchestrator", "0040_launch_requests"])
    }

    @Test("MigrationVersion identity: a filename reduces to its ledger version")
    func migrationVersionIdentity() {
        // The filename IS the ledger version (BR-MIG-04).
        let v = MigrationVersion(name: "048_spec", ordinal: 48, fileName: "048_spec.sql")
        #expect(v.description == "048_spec")
        #expect(v.fileName == v.name + ".sql")
    }

    // MARK: - versions(in:) and the Resolution

    @Test("adding a migration file changes the expectation with no hand edit")
    func addingAMigrationFileMovesTheExpectation() throws {
        let dir = try plant(
            ["048_spec.sql", "049_spec_rename.sql", "050_spec_revision.sql"],
            scope: "manifest-add-file")
        defer { cleanUp(dir) }

        let before = try MigrationManifest.versions(in: dir).count

        // The whole change: one file on disk. No Swift source is edited.
        try "-- 051\n".write(
            to: dir.appendingPathComponent("051_ledger_reconcile.sql"),
            atomically: true, encoding: .utf8)

        let after = try MigrationManifest.versions(in: dir).count
        #expect(after == before + 1, "before=\(before) after=\(after)")
    }

    @Test("rollback files are not ledger entries, and .up registers under its bare name")
    func rollbackFilesSkipped() throws {
        let dir = try plant(
            [
                "043_plan_kind.up.sql", "043_plan_kind.down.sql",
                "044_user_profile.sql", "README.md",
            ],
            scope: "manifest-up-down")
        defer { cleanUp(dir) }

        let shipped = try MigrationManifest.versions(in: dir)
        #expect(shipped.map(\.name) == ["043_plan_kind", "044_user_profile"])
        #expect(shipped.first?.fileName == "043_plan_kind.up.sql")
    }

    @Test("an unnumbered migration is refused and a duplicate number is reported")
    func unnumberedRefusedDuplicateReported() throws {
        let bad = try plant(["add_backlog_table.sql"], scope: "manifest-unnumbered")
        defer { cleanUp(bad) }

        #expect(throws: MigrationManifestError.unnumbered(fileName: "add_backlog_table.sql")) {
            _ = try MigrationManifest.versions(in: bad)
        }

        // Four files sharing `0002` is the live shape of the dead directory
        // W3 deletes (§1.1). The manifest names the collision.
        let dupes = try plant(
            ["0002_audit.sql", "0002_consent.sql", "0003_other.sql"],
            scope: "manifest-dupes")
        defer { cleanUp(dupes) }

        let resolution = MigrationManifest.Resolution(
            versions: try MigrationManifest.versions(in: dupes),
            source: .scanned(path: dupes.path))
        #expect(resolution.duplicateOrdinals == [2])
    }

    @Test("the directory is unreadable when the path does not exist")
    func unreadableDirectoryThrows() {
        let absent = testPaths.sandbox("no-such-dir")
        #expect(throws: MigrationManifestError.unreadable(path: absent.path)) {
            _ = try MigrationManifest.versions(in: absent)
        }
    }

    // MARK: - resolve(bundle:) and the snapshot seam

    @Test("resolve(bundle:) reads the migrations resource shipped inside the bundle")
    func resolveReadsTheBundleResource() throws {
        let bundle = try plantBundle(migrations: ["070_a.sql", "071_b.sql"], scope: "bundle-read")
        defer { cleanUp(bundle.bundleURL) }

        let directory = MigrationManifest.migrationsDirectory(in: bundle)
        #expect(directory?.lastPathComponent == "migrations")

        let resolution = MigrationManifest.resolve(bundle: bundle)
        #expect(resolution.versions.map(\.name) == ["070_a", "071_b"])
        #expect(resolution.sourceLabel == "scanned")
        guard case .scanned(let path) = resolution.source else {
            Issue.record("expected a scanned source, got \(resolution.source)")
            return
        }
        #expect(
            URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(bundle.bundleURL.standardizedFileURL.path),
            "the only place the kit reads is the bundle")
    }

    @Test("a bundle built without the resource degrades loudly to the caller's snapshot and names the fix")
    func bundleWithoutResourceDegradesLoudly() throws {
        let bundle = try plantBundle(migrations: nil, scope: "bundle-empty")
        defer { cleanUp(bundle.bundleURL) }
        let snapshot = [
            MigrationVersion(name: "001_a", ordinal: 1, fileName: "001_a.sql"),
            MigrationVersion(name: "002_b", ordinal: 2, fileName: "002_b.sql"),
        ]

        #expect(MigrationManifest.migrationsDirectory(in: bundle) == nil)
        let resolution = MigrationManifest.resolve(bundle: bundle, snapshot: snapshot)

        guard case .snapshot(let reason) = resolution.source else {
            Issue.record("expected a snapshot fallback, got \(resolution.source)")
            return
        }
        #expect(reason.contains("resources: [.copy(\"migrations\")]"), "the degradation says what the consumer must declare")
        #expect(reason.contains(bundle.bundleURL.lastPathComponent))
        #expect(resolution.versions.map(\.name) == ["001_a", "002_b"])
        #expect(resolution.sourceLabel == "snapshot")
    }

    @Test("a consumer may name its resource folder; a file where the folder should be is not a resource")
    func directoryNameIsHonouredAndAFileIsRefused() throws {
        let bundle = try plantBundle(migrations: nil, scope: "bundle-named")
        defer { cleanUp(bundle.bundleURL) }
        let schema = bundle.bundleURL.appendingPathComponent("schema", isDirectory: true)
        try FileManager.default.createDirectory(at: schema, withIntermediateDirectories: true)
        try "-- fixture\n".write(to: schema.appendingPathComponent("080_c.sql"), atomically: true, encoding: .utf8)
        try "not a directory".write(
            to: bundle.bundleURL.appendingPathComponent("migrations"), atomically: true, encoding: .utf8)

        #expect(MigrationManifest.resolve(bundle: bundle, directoryName: "schema").versions.map(\.name) == ["080_c"])
        #expect(MigrationManifest.migrationsDirectory(in: bundle) == nil, "a plain file named migrations is not the resource")
        #expect(MigrationManifest.resolve(bundle: bundle).sourceLabel == "snapshot")
    }

    @Test("missing(applied:) is identity-based, never a count (BR-MIG-08)")
    func missingIsIdentityBased() {
        let shipped = [
            MigrationVersion(name: "048_spec", ordinal: 48, fileName: "048_spec.sql"),
            MigrationVersion(name: "049_rename", ordinal: 49, fileName: "049_rename.sql"),
            MigrationVersion(name: "050_rev", ordinal: 50, fileName: "050_rev.sql"),
        ]
        let resolution = MigrationManifest.Resolution(
            versions: shipped, source: .scanned(path: "/dev/null"))

        // An empty ledger: every shipped version is missing.
        #expect(resolution.missing(applied: []) == ["048_spec", "049_rename", "050_rev"])

        // A ledger that has grown past shipped — a count would refuse this,
        // identity does not (BR-MIG-08, panel e7061336 Critical).
        let bigger: Set<String> = ["000_old", "001_old", "048_spec", "049_rename", "050_rev"]
        #expect(resolution.missing(applied: bigger).isEmpty)

        // A ledger missing one shipped name — degraded, identified by name.
        let missing_one: Set<String> = ["048_spec", "050_rev"]
        #expect(resolution.missing(applied: missing_one) == ["049_rename"])
    }
}

// MARK: - MigrationLedger — static verification, pure (no database)

@Suite("MigrationLedger (c8b11718 W5) — static verification of a .sql file's ledger declaration")
struct MigrationLedgerVerificationTests {

    @Test("version(ofFileNamed:) strips .sql and any .up/.down")
    func versionReductionBR_MIG_04() {
        #expect(MigrationLedger.version(ofFileNamed: "048_spec.sql") == "048_spec")
        #expect(MigrationLedger.version(ofFileNamed: "043_plan.up.sql") == "043_plan")
        #expect(MigrationLedger.version(ofFileNamed: "043_plan.down.sql") == "043_plan")
    }

    @Test("a file whose registered version differs from its filename is refused")
    func filenameVersionMismatchIsRefused() throws {
        let mismatched = """
            BEGIN;
            CREATE TABLE IF NOT EXISTS widget (id INT);
            INSERT INTO schema_migrations(version) VALUES ('099_widget_v2')
                ON CONFLICT (version) DO NOTHING;
            COMMIT;
            """
        #expect(
            throws: MigrationLedger.Violation.registersForeignVersion(
                file: "099_widget.sql",
                registered: "099_widget_v2",
                expected: "099_widget")
        ) {
            try MigrationLedger.verify(fileNamed: "099_widget.sql", sql: mismatched)
        }
    }

    @Test("branching on the ledger — 048's original defect — is refused")
    func branchingOnTheLedgerIsRefused() throws {
        // Verbatim structure of the removed compat branch.
        let original = """
            BEGIN;
            DO $migration$
            DECLARE
                pre_canonical text := '048_spec_v' || '2';
            BEGIN
                IF EXISTS (SELECT 1 FROM schema_migrations WHERE version = pre_canonical) THEN
                    INSERT INTO schema_migrations(version) VALUES ('048_spec') ON CONFLICT (version) DO NOTHING;
                    RETURN;
                END IF;
                CREATE TABLE IF NOT EXISTS spec (id INT);
            END;
            $migration$;
            COMMIT;
            """
        let violation = #expect(throws: MigrationLedger.Violation.self) {
            try MigrationLedger.verify(fileNamed: "048_spec.sql", sql: original)
        }
        // Refused for the branch, which is the cause, rather than for the
        // version literal, which is only the symptom.
        guard case .branchesOnLedger = try #require(violation) else {
            Issue.record("refused for the wrong reason: \(String(describing: violation))")
            return
        }
    }

    @Test("the other four ways to lie to the ledger are each refused")
    func theRemainingLedgerViolationsAreRefused() throws {
        // A migration that never records itself re-applies on every run.
        let registersNothing = "CREATE TABLE IF NOT EXISTS t (id INT);"
        #expect(throws: MigrationLedger.Violation.self) {
            try MigrationLedger.verify(fileNamed: "060_thing.sql", sql: registersNothing)
        }

        // A version assembled with `||` is invisible to both the runner and
        // grep.
        let assembled = "INSERT INTO schema_migrations(version) VALUES ('060_thi' || 'ng');"
        #expect(throws: MigrationLedger.Violation.self) {
            try MigrationLedger.verify(fileNamed: "060_thing.sql", sql: assembled)
        }

        // A predicate whose value is not in the file cannot be read from the
        // file.
        let nonLiteral = """
            DO $m$ DECLARE v text := 'x'; BEGIN
                DELETE FROM schema_migrations WHERE version = v;
            END; $m$;
            INSERT INTO schema_migrations(version) VALUES ('060_thing');
            """
        #expect(throws: MigrationLedger.Violation.self) {
            try MigrationLedger.verify(fileNamed: "060_thing.sql", sql: nonLiteral)
        }

        // An unjustified `@ledger-registers:` directive — the widening with
        // no reason given.
        let unjustified = """
            -- @ledger-registers: 048_spec
            INSERT INTO schema_migrations(version) VALUES ('052_ledger_reconcile');
            UPDATE schema_migrations SET version = '048_spec' WHERE version = '048_spec_v2';
            """
        let violation = #expect(throws: MigrationLedger.Violation.self) {
            try MigrationLedger.verify(fileNamed: "052_ledger_reconcile.sql", sql: unjustified)
        }
        guard case .unjustifiedAllowance = try #require(violation) else {
            Issue.record("expected unjustifiedAllowance, got \(String(describing: violation))")
            return
        }
    }

    @Test("an UPDATE/DELETE on schema_migrations with no header is refused")
    func undeclaredLedgerMutationIsRefused() throws {
        let undeclared = """
            INSERT INTO schema_migrations(version) VALUES ('052_ledger_reconcile');
            UPDATE schema_migrations SET version = '048_spec' WHERE version = '048_spec_v2';
            """
        let violation = #expect(throws: MigrationLedger.Violation.self) {
            try MigrationLedger.verify(fileNamed: "052_ledger_reconcile.sql", sql: undeclared)
        }
        // The UPDATE on another row names a foreign version; the detector
        // catches that identity defect first, before it even looks at the
        // header-less mutation. Either is a true refusal; this test asserts
        // the file is refused.
        _ = try #require(violation)
    }

    @Test("a well-formed migration passes verify")
    func wellFormedMigrationPasses() throws {
        let ok = """
            BEGIN;
            CREATE TABLE IF NOT EXISTS widget (id INT);
            INSERT INTO schema_migrations(version) VALUES ('099_widget')
                ON CONFLICT (version) DO NOTHING;
            COMMIT;
            """
        #expect(throws: Never.self) {
            try MigrationLedger.verify(fileNamed: "099_widget.sql", sql: ok)
        }
    }

    @Test("a reconciliation declaring @ledger-registers with a reason passes")
    func reconciliationWithJustificationPasses() throws {
        let reconcile = """
            -- @ledger-registers: 048_spec — retires the pre-canonical row
            BEGIN;
            UPDATE schema_migrations
               SET version = '048_spec'
             WHERE version = '048_spec_v2';
            INSERT INTO schema_migrations(version) VALUES ('052_ledger_reconcile')
                ON CONFLICT (version) DO NOTHING;
            COMMIT;
            """
        #expect(throws: Never.self) {
            try MigrationLedger.verify(fileNamed: "052_ledger_reconcile.sql", sql: reconcile)
        }
    }

    @Test("declaration() reads what the file says about the ledger")
    func declarationReadsFile() {
        let sql = """
            -- @ledger-registers: 048_spec — rename
            INSERT INTO schema_migrations(version) VALUES ('052_ledger_reconcile');
            UPDATE schema_migrations SET version = '048_spec' WHERE version = '048_spec_v2';
            """
        let d = MigrationLedger.declaration(
            forFileNamed: "052_ledger_reconcile.sql", sql: sql)
        #expect(d.version == "052_ledger_reconcile")
        #expect(d.registers == ["052_ledger_reconcile"])
        #expect(d.allowances.map(\.version) == ["048_spec"])
        #expect(d.mutatesOtherRows == true)
    }

    @Test("applicableStatements drops transaction control the runner owns")
    func applicableStatementsDropsBeginCommit() {
        let sql = """
            BEGIN;
            CREATE TABLE IF NOT EXISTS widget (id INT);
            INSERT INTO schema_migrations(version) VALUES ('099_widget');
            COMMIT;
            """
        let out = MigrationLedger.applicableStatements(sql)
        let joined = out.joined(separator: " | ").lowercased()
        #expect(!joined.contains("begin"))
        #expect(!joined.contains("commit"))
        #expect(out.contains { $0.contains("CREATE TABLE") })
        #expect(out.contains { $0.contains("INSERT INTO schema_migrations") })
    }

    @Test("verifyAll walks a directory and refuses the first violation")
    func verifyAllIsTheDirectoryRatchet() throws {
        let dir = testPaths.sandbox("verifyall")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { testPaths.discard(dir) }

        try """
        CREATE TABLE IF NOT EXISTS widget (id INT);
        INSERT INTO schema_migrations(version) VALUES ('099_widget')
            ON CONFLICT (version) DO NOTHING;
        """.write(
            to: dir.appendingPathComponent("099_widget.sql"),
            atomically: true, encoding: .utf8)
        try """
        CREATE TABLE IF NOT EXISTS gadget (id INT);
        INSERT INTO schema_migrations(version) VALUES ('100_gadget_v2');
        """.write(
            to: dir.appendingPathComponent("100_gadget.sql"),
            atomically: true, encoding: .utf8)

        #expect(throws: MigrationLedger.Violation.self) {
            try MigrationLedger.verifyAll(in: dir)
        }
    }
}

// MARK: - MigrationLedgerContract — the parameterised DDL and the identity gate

@Suite("MigrationLedgerContract (c8b11718 W5) — one DDL for the ledger table")
struct MigrationLedgerContractTests {

    @Test("default contract names schema_migrations with Postgres-style quoting")
    func defaultsAreTheFleetShape() {
        let c = MigrationLedgerContract()
        #expect(c.tableName == "schema_migrations")
        #expect(c.identifierQuote == "\"")
        #expect(c.quotedTableName == #""schema_migrations""#)
    }

    @Test("createTableSQL carries the ledger shape every adapter reads back")
    func createTableSQLShape() {
        let c = MigrationLedgerContract()
        let ddl = c.createTableSQL
        #expect(ddl.contains("CREATE TABLE IF NOT EXISTS \"schema_migrations\""))
        #expect(ddl.contains("version TEXT PRIMARY KEY"))
        #expect(ddl.contains("applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()"))
    }

    @Test("selectAllVersionsSQL is the probe adapters use to read the applied set")
    func selectAllVersionsSQL() {
        #expect(
            MigrationLedgerContract().selectAllVersionsSQL
                == "SELECT version FROM \"schema_migrations\" ORDER BY version")
    }

    @Test("a plugin or test may name its own table and quoting")
    func parametersAllowAlternativeAdapters() {
        let c = MigrationLedgerContract(
            tableName: "plugin_schema_migrations", identifierQuote: "`")
        #expect(c.quotedTableName == "`plugin_schema_migrations`")
        #expect(c.createTableSQL.contains("`plugin_schema_migrations`"))
    }

    @Test("missing(shipped:applied:) is identity, not a count (BR-MIG-08)")
    func missingIsIdentity() {
        let shipped = [
            MigrationVersion(name: "001_a", ordinal: 1, fileName: "001_a.sql"),
            MigrationVersion(name: "002_b", ordinal: 2, fileName: "002_b.sql"),
            MigrationVersion(name: "003_c", ordinal: 3, fileName: "003_c.sql"),
        ]
        #expect(
            MigrationLedgerContract.missing(shipped: shipped, applied: ["001_a", "002_b"])
                == ["003_c"])
        // A ledger that holds extra, unrecognised versions is NOT refused —
        // identity names what is missing, not what is foreign.
        #expect(
            MigrationLedgerContract.missing(
                shipped: shipped,
                applied: ["000_prior", "001_a", "002_b", "003_c", "099_other"]
            ).isEmpty)
    }
}

// MARK: - MigrationStore + MigrationApplyOutcome

@Suite("MigrationStore (c8b11718 W5) — the one protocol every adapter conforms to")
struct MigrationStoreTests {

    @Test("MigrationApplyOutcome.noop is the already-applied shape")
    func noopShape() {
        let noop = MigrationApplyOutcome.noop(version: "048_spec")
        #expect(noop.version == "048_spec")
        #expect(noop.applied == false)
        #expect(noop.gained.isEmpty)
        #expect(noop.lost.isEmpty)
    }

    @Test("a stub MigrationStore composes with missing(from:)")
    func stubStoreComposes() async throws {
        let shipped = [
            MigrationVersion(name: "048_spec", ordinal: 48, fileName: "048_spec.sql"),
            MigrationVersion(name: "049_rename", ordinal: 49, fileName: "049_rename.sql"),
            MigrationVersion(name: "050_rev", ordinal: 50, fileName: "050_rev.sql"),
        ]
        let store = StubMigrationStore(applied: ["048_spec", "050_rev"])
        let missing = try await store.missing(from: shipped)
        #expect(missing == ["049_rename"])
    }
}

private struct StubMigrationStore: MigrationStore {
    let applied: Set<String>
    func appliedMigrationVersions() async throws -> Set<String> { applied }
    func applyMigration(at url: URL) async throws -> MigrationApplyOutcome {
        .noop(version: MigrationLedger.version(ofFileNamed: url.lastPathComponent))
    }
}

// MARK: - T-18: the core imports no driver

@Suite("BackendKitMigrations (c8b11718 W5, T-18) — Foundation only, no dependency")
struct MigrationCoreIsFoundationOnlyTests {

    private static let packageRoot = TestPackagePaths.packageRoot()
    private static let coreTarget = "BackendKitMigrations"

    @Test("every source file imports Foundation and nothing else")
    func sourcesImportOnlyFoundation() throws {
        let sources = Self.packageRoot.appendingPathComponent("Sources").appendingPathComponent(Self.coreTarget)
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        #expect(files.count == 4, "the migration core is the four files moved from shikki-plugin-api: \(files)")
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            let imports = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("import ") || $0.hasPrefix("@_exported import ") || $0.hasPrefix("@testable import ") }
            #expect(imports == ["import Foundation"], "\(file) imports \(imports)")
        }
    }

    @Test("Package.swift declares the target with an empty dependency list")
    func manifestDeclaresNoDependency() throws {
        let manifest = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let declaration = try #require(
            manifest.range(of: ".target(\n            name: \"\(Self.coreTarget)\","),
            "the \(Self.coreTarget) target is not declared in Package.swift")
        let rest = manifest[declaration.upperBound...]
        let closing = try #require(rest.range(of: "\n        ),"))
        let block = rest[..<closing.lowerBound]
        #expect(block.contains("dependencies: []"), "\(Self.coreTarget) must declare no dependency: \(block)")
        #expect(!block.contains(".product("), "\(Self.coreTarget) must not use a product: \(block)")
    }
}
