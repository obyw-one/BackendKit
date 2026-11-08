// MOVED — originally Sources/ShikkiPluginAPI/Migrations/MigrationLedgerContract.swift in shikki-plugin-api v0.15.0
// (commit 5d5c039b), also mirrored verbatim as KagamiMigrationCore. Everything below this block is
// that file, unchanged: same type names, same behaviour.
//
// BackendKitMigrations is the public, Foundation-only home of the engine-agnostic migration core
// (BR-MIG-11, operator decision 2026-11-08). It declares no dependency, so a consumer that links it
// (kagami, shikki-plugin-api) pulls no NIO, Postgres, SQLite or DuckDB into its build. The SQL
// adapters live beside their engines: `SQLMigrationStore` in BackendKitSQL.

// MigrationLedgerContract.swift — the ledger-table contract and the SQL rules
// every adapter enforces before a file reaches a server.
//
// Spec: one-migration-runner-one-ledger-2026-10-01 (c8b11718) W5, BR-MIG-11:
// "the naming + ledger rules, the ledger-table contract (table name and
// quoting as parameters, DDL owned by the kit), `missing(shipped:applied:)`"
//
// Three pieces, extracted from `ShikkiMCPPostgresKit/MigrationManifest.swift`
// so a second adapter never writes its own:
//
//   1. `MigrationLedgerContract` — the parameterised DDL for the ledger table,
//      because an adapter should name the table and quote the identifier, not
//      invent the schema.
//   2. `MigrationLedger` — the static verification of what a `.sql` file
//      declares about `schema_migrations`. Pure: no database, no I/O beyond
//      the string it is handed. The apply-time refusal (every adapter's
//      `applyMigration`) runs this first, so a violating file never reaches
//      the server.
//   3. `missing(shipped:applied:)` — the identity-based gate (BR-MIG-08).
//      `shipped − applied` by name, so an empty ledger is "not bootstrapped"
//      and a non-empty ledger lacking a shipped name is "degraded"; a count
//      cannot say either.

import Foundation

// MARK: - MigrationLedgerContract — the one place DDL is written

/// The contract an adapter uses to create and read the ledger table.
///
/// Table name and quoting are parameters, but the DDL is owned by the kit:
/// an adapter never writes its own `CREATE TABLE`, and the shape every
/// consumer reads is identical.
public struct MigrationLedgerContract: Sendable, Equatable {
    /// The ledger table's identifier. Default is `schema_migrations`, the
    /// name the fleet already runs on; a plugin or test may name its own.
    public let tableName: String
    /// How to quote an identifier for the target engine. Default is Postgres'
    /// double quotes; SQLite accepts the same form, but a MySQL adapter
    /// would pass backticks instead.
    public let identifierQuote: String

    public init(tableName: String = "schema_migrations", identifierQuote: String = "\"") {
        self.tableName = tableName
        self.identifierQuote = identifierQuote
    }

    /// The quoted identifier for the ledger table, inlined into statements.
    public var quotedTableName: String {
        "\(identifierQuote)\(tableName)\(identifierQuote)"
    }

    /// DDL that creates the ledger table if it is not already present. The
    /// shape every adapter writes against: `(version TEXT PRIMARY KEY,
    /// applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW())`.
    public var createTableSQL: String {
        """
        CREATE TABLE IF NOT EXISTS \(quotedTableName) (
            version TEXT PRIMARY KEY,
            applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """
    }

    /// `SELECT version FROM <table> ORDER BY version` — the probe every
    /// adapter uses to read the applied set.
    public var selectAllVersionsSQL: String {
        "SELECT version FROM \(quotedTableName) ORDER BY version"
    }

    /// Shipped versions the ledger does not hold, in migration order. Empty
    /// means the ledger is current. The identity-based gate (BR-MIG-08).
    public static func missing(
        shipped: [MigrationVersion],
        applied: Set<String>
    ) -> [String] {
        shipped.filter { !applied.contains($0.name) }.map(\.name)
    }
}

// MARK: - MigrationLedger — static verification of what a .sql file declares
//
// Spec: one-migration-runner-one-ledger-2026-10-01 (c8b11718) W2 verbatim,
//       moved into the engine-agnostic kit by W5.
//
// WHY THIS EXISTS. `048_spec.sql` registered itself in `schema_migrations` as
// `048_spec_v2` and then reconciled the disagreement with a branch inside its
// own body: it SELECTed the ledger, found the pre-canonical version and
// INSERTed the canonical one in its place. A migration that decides its own
// identity by reading the table it is migrating cannot be reasoned about from
// its filename, which is the one thing a migration runner has to go on.
//
// The rule is small and mechanical: the version a file registers is its
// filename. A file that legitimately touches another file's ledger row — a
// reconciliation, which `052_ledger_reconcile.sql` is — declares it in one
// grep-able header line (`@ledger-registers:`) with a justification, instead
// of hiding it in a conditional. Everything else is refused before a single
// statement runs.

/// Static verification of what a migration file does to `schema_migrations`.
///
/// Pure: no database, no I/O beyond the string it is handed.
public enum MigrationLedger: Sendable {

    /// A header line widening what a file may register, e.g.
    /// `-- @ledger-registers: 048_spec — retires the pre-canonical row`.
    public struct Allowance: Hashable, Sendable {
        public let version: String
        /// The rest of the directive line. Required: an undocumented widening
        /// is how the branch this rule removes got in.
        public let justification: String

        public init(version: String, justification: String) {
            self.version = version
            self.justification = justification
        }
    }

    /// What a file declares about the ledger, read from its text.
    public struct Declaration: Sendable, Equatable {
        /// The filename stem — per BR-MIG-04, the version this file must register.
        public let version: String
        /// Version literals the file writes into `schema_migrations`.
        public let registers: [String]
        /// Versions the file is permitted to write besides its own.
        public let allowances: [Allowance]
        /// `true` if the file UPDATEs or DELETEs rows in `schema_migrations`.
        public let mutatesOtherRows: Bool

        public init(
            version: String,
            registers: [String],
            allowances: [Allowance],
            mutatesOtherRows: Bool
        ) {
            self.version = version
            self.registers = registers
            self.allowances = allowances
            self.mutatesOtherRows = mutatesOtherRows
        }
    }

    public enum Violation: Error, Equatable, CustomStringConvertible {
        /// The headline defect: the file registers a version that is not its name.
        case registersForeignVersion(file: String, registered: String, expected: String)
        /// A migration that never records itself is applied once per run, forever.
        case registersNothing(file: String, expected: String)
        /// A version string built with `||` where the file registers itself —
        /// unreadable to the runner and invisible to a source grep.
        case assembledVersionLiteral(file: String, statement: String)
        /// `IF EXISTS (SELECT … FROM schema_migrations …)` — control flow keyed
        /// on the ledger, which is 048's original defect.
        case branchesOnLedger(file: String, fragment: String)
        /// `WHERE version = <identifier>` — a predicate whose value is not in
        /// the file, so what it matches cannot be known by reading it.
        case nonLiteralVersionPredicate(file: String, fragment: String)
        /// UPDATE/DELETE against `schema_migrations` with no `@ledger-registers:`
        /// header declaring the reconciliation.
        case undeclaredLedgerMutation(file: String, statement: String)
        /// A widening with no reason given.
        case unjustifiedAllowance(file: String, version: String)

        public var description: String {
            switch self {
            case .registersForeignVersion(let file, let registered, let expected):
                return
                    "\(file) registers '\(registered)' but its filename is '\(expected)' — BR-MIG-04: the filename IS the ledger version"
            case .registersNothing(let file, let expected):
                return
                    "\(file) never INSERTs '\(expected)' into schema_migrations — it would re-apply on every run"
            case .assembledVersionLiteral(let file, let statement):
                return "\(file) assembles the version it registers with '||': \(statement)"
            case .branchesOnLedger(let file, let fragment):
                return
                    "\(file) branches on schema_migrations contents (\(fragment)) — a migration may not reconcile the ledger from inside its own body"
            case .nonLiteralVersionPredicate(let file, let fragment):
                return "\(file) matches a version against a non-literal (\(fragment))"
            case .undeclaredLedgerMutation(let file, let statement):
                return
                    "\(file) rewrites other rows in schema_migrations with no '-- @ledger-registers:' declaration: \(statement)"
            case .unjustifiedAllowance(let file, let version):
                return
                    "\(file) declares '-- @ledger-registers: \(version)' with no justification after it"
            }
        }
    }

    /// The directive this rule is configured by.
    public static let allowanceDirective = "@ledger-registers:"

    // MARK: - Reading a file

    /// The ledger version a file named `fileName` must register: the stem,
    /// with `.sql` and any `.up` removed. `048_spec.sql` → `048_spec`.
    public static func version(ofFileNamed fileName: String) -> String {
        var name = fileName
        if name.hasSuffix(".sql") { name = String(name.dropLast(4)) }
        if name.hasSuffix(".up") || name.hasSuffix(".down") {
            name = String(name[name.startIndex..<name.lastIndex(of: ".")!])
        }
        return name
    }

    /// Parse what `sql` declares about the ledger. Never throws — `verify`
    /// decides what is a violation.
    public static func declaration(forFileNamed fileName: String, sql: String) -> Declaration {
        let expected = version(ofFileNamed: fileName)
        let allowances = parseAllowances(sql)
        let body = strippingComments(sql)
        var registers: [String] = []
        var mutates = false
        for statement in topLevelStatements(body) {
            let flat = statement.replacingOccurrences(of: "\n", with: " ")
            let lower = flat.lowercased()
            guard lower.contains("schema_migrations") else { continue }
            if lower.contains("update schema_migrations")
                || lower.contains("delete from schema_migrations") {
                mutates = true
            }
            guard let head = registerClause(of: flat) else { continue }
            registers.append(contentsOf: stringLiterals(in: head).filter { $0.first?.isNumber == true })
        }
        return Declaration(
            version: expected,
            registers: registers,
            allowances: allowances,
            mutatesOtherRows: mutates)
    }

    /// Refuse a file that does not obey BR-MIG-04. Throws the first violation
    /// — one clear reason beats a list nobody reads.
    public static func verify(fileNamed fileName: String, sql: String) throws {
        let declaration = declaration(forFileNamed: fileName, sql: sql)

        for allowance in declaration.allowances where allowance.justification.isEmpty {
            throw Violation.unjustifiedAllowance(file: fileName, version: allowance.version)
        }

        let body = strippingComments(sql)
        if let fragment = ledgerBranch(in: body) {
            throw Violation.branchesOnLedger(file: fileName, fragment: fragment)
        }
        if let fragment = nonLiteralVersionPredicate(in: body) {
            throw Violation.nonLiteralVersionPredicate(file: fileName, fragment: fragment)
        }

        for statement in topLevelStatements(body) {
            let flat = statement.replacingOccurrences(of: "\n", with: " ")
            guard flat.lowercased().contains("insert into schema_migrations"),
                let head = registerClause(of: flat)
            else { continue }
            if head.contains("||") {
                throw Violation.assembledVersionLiteral(file: fileName, statement: collapse(flat))
            }
        }

        var allowed = Set(declaration.allowances.map(\.version))
        allowed.insert(declaration.version)
        for registered in declaration.registers where !allowed.contains(registered) {
            throw Violation.registersForeignVersion(
                file: fileName, registered: registered, expected: declaration.version)
        }
        if !declaration.registers.contains(declaration.version) {
            throw Violation.registersNothing(file: fileName, expected: declaration.version)
        }
        if declaration.mutatesOtherRows, declaration.allowances.isEmpty {
            throw Violation.undeclaredLedgerMutation(
                file: fileName,
                statement: "UPDATE/DELETE on schema_migrations")
        }
    }

    /// Verify every `.sql` file in `directory`. The ratchet that keeps the
    /// next compat branch out.
    public static func verifyAll(in directory: URL) throws {
        for version in try MigrationManifest.versions(in: directory) {
            let url = directory.appendingPathComponent(version.fileName)
            let sql = try String(contentsOf: url, encoding: .utf8)
            try verify(fileNamed: version.fileName, sql: sql)
        }
    }

    /// The statements a runner should send, in order: comment-stripped, split
    /// so a driver can prepare one at a time, with `$tag$ … $tag$` plpgsql
    /// bodies kept whole and the file's own `BEGIN`/`COMMIT`/`ROLLBACK`
    /// removed.
    ///
    /// Transaction control is dropped because the runner owns the transaction
    /// (every adapter's `applyMigration` wraps the whole apply): a `COMMIT`
    /// from inside the file would close that transaction early and take its
    /// rollback with it. Every statement the file actually performs is
    /// preserved.
    public static func applicableStatements(_ sql: String) -> [String] {
        topLevelStatements(strippingComments(sql)).filter { statement in
            let normalized = statement.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !["begin", "commit", "rollback", "start transaction", "end"].contains(normalized)
        }
    }

    // MARK: - Internals

    /// Directives live in comments, so they are read from the raw text.
    private static func parseAllowances(_ sql: String) -> [Allowance] {
        var found: [Allowance] = []
        for line in sql.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("--"), let range = trimmed.range(of: allowanceDirective) else {
                continue
            }
            let rest = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let versionToken = rest.split(separator: " ").first.map(String.init),
                !versionToken.isEmpty
            else { continue }
            let justification = rest.dropFirst(versionToken.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " —-:"))
            found.append(Allowance(version: versionToken, justification: justification))
        }
        return found
    }

    /// The part of an INSERT that says what version is being written — the
    /// VALUES/SELECT list, before any `FROM` or `WHERE`. A reconciliation's
    /// own predicate names the row it retires, which is not a registration.
    private static func registerClause(of statement: String) -> String? {
        let lower = statement.lowercased()
        guard let insert = lower.range(of: "insert into schema_migrations") else { return nil }
        var end = statement.endIndex
        for keyword in [" from ", " where ", " on conflict"] {
            if let found = lower.range(of: keyword, range: insert.upperBound..<lower.endIndex),
                found.lowerBound < end {
                end = found.lowerBound
            }
        }
        return String(statement[insert.upperBound..<end])
    }

    private static func stringLiterals(in fragment: String) -> [String] {
        var out: [String] = []
        var current: String?
        for character in fragment {
            if character == "'" {
                if let value = current {
                    out.append(value)
                    current = nil
                } else {
                    current = ""
                }
            } else if current != nil {
                current?.append(character)
            }
        }
        return out
    }

    /// `IF [NOT] EXISTS (SELECT … schema_migrations …)` or `IF (SELECT …
    /// schema_migrations …)`. Deliberately narrow: a view or a CTE that reads
    /// the ledger is fine, control flow keyed on it is not.
    private static func ledgerBranch(in body: String) -> String? {
        let lower = body.lowercased()
        var searchStart = lower.startIndex
        while let ifRange = lower.range(of: "if ", range: searchStart..<lower.endIndex) {
            searchStart = ifRange.upperBound
            let tail =
                lower.range(of: " then", range: ifRange.upperBound..<lower.endIndex)?.lowerBound
                ?? lower.endIndex
            let condition = lower[ifRange.upperBound..<tail]
            // A plpgsql `IF … THEN` condition holds no statement terminator.
            // This is what tells a branch apart from `CREATE TABLE IF NOT
            // EXISTS`, whose "condition" would otherwise run to the end of
            // the file.
            if condition.contains(";") { continue }
            if condition.contains("schema_migrations"), condition.contains("select") {
                return collapse(String(body[ifRange.lowerBound..<tail]))
            }
        }
        return nil
    }

    /// `version = pre_canonical` — a predicate whose value is not in the file.
    /// `version = '048_spec'`, `version = ANY(...)` and `version ~ '^[0-9]'`
    /// are all literal enough to read.
    private static func nonLiteralVersionPredicate(in body: String) -> String? {
        let lower = body.lowercased()
        var searchStart = lower.startIndex
        while let match = lower.range(of: "version =", range: searchStart..<lower.endIndex) {
            searchStart = match.upperBound
            let rest = lower[match.upperBound...].drop(while: { $0 == " " || $0 == "\n" })
            guard let first = rest.first else { continue }
            if first == "'" || first == "$" { continue }
            let token = String(rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
            if token.isEmpty || ["any", "null", "excluded", "current_setting"].contains(token) {
                continue
            }
            // A qualified column (`g.version = k.version`) is a join, not a
            // lookup.
            if rest.dropFirst(token.count).first == "." { continue }
            return "version = \(token)"
        }
        return nil
    }

    /// Comment-stripped SQL. `--` to end of line; the migrations carry no
    /// `/* */`.
    private static func strippingComments(_ sql: String) -> String {
        sql.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let marker = line.range(of: "--") else { return String(line) }
                // A `--` inside a string literal is not a comment. Treating
                // one as a comment would only ever make this check stricter,
                // never laxer.
                let before = line[line.startIndex..<marker.lowerBound]
                guard before.filter({ $0 == "'" }).count % 2 == 0 else { return String(line) }
                return String(before)
            }
            .joined(separator: "\n")
    }

    /// Split on top-level `;`, keeping `$tag$ … $tag$` bodies whole.
    private static func topLevelStatements(_ sql: String) -> [String] {
        var out: [String] = []
        var current = ""
        var dollarTag: String?
        var inString = false
        let characters = Array(sql)
        var index = 0
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(trimmed) }
            current = ""
        }
        while index < characters.count {
            let character = characters[index]
            if let tag = dollarTag {
                if character == "$",
                    String(characters[index..<min(characters.count, index + tag.count)]) == tag {
                    current += tag
                    index += tag.count
                    dollarTag = nil
                    continue
                }
                current.append(character)
                index += 1
                continue
            }
            if inString {
                current.append(character)
                if character == "'" { inString = false }
                index += 1
                continue
            }
            if character == "'" {
                inString = true
                current.append(character)
                index += 1
                continue
            }
            if character == "$" {
                var end = index + 1
                while end < characters.count,
                    characters[end].isLetter || characters[end].isNumber || characters[end] == "_"
                { end += 1 }
                if end < characters.count, characters[end] == "$" {
                    let tag = String(characters[index...end])
                    dollarTag = tag
                    current += tag
                    index = end + 1
                    continue
                }
            }
            if character == ";" {
                flush()
                index += 1
                continue
            }
            current.append(character)
            index += 1
        }
        flush()
        return out
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
