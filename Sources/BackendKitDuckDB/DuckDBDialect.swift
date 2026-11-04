import SQLKit

// MARK: - DuckDBDialect

//
// DuckDB's SQL is Postgres-flavoured, so this starts from `PostgresDialect` and changes
// only what differs (each point verified against DuckDB 1.1, not assumed):
//   - `$n` placeholders are kept (DuckDB accepts `$1`), `"` identifier quote and `'` string quote too.
//   - NO `GENERATED ... AS IDENTITY`: DuckDB has no identity columns (auto ids are
//     `DEFAULT nextval('seq')`). An auto-increment key therefore renders as
//     `DEFAULT nextval('backendkit_autoincrement') PRIMARY KEY`; the host creates that ONE
//     shared sequence at open (ids are unique and increasing across tables, not gap-free per table).
//   - Enums are `.unsupported` (SQLKit then models them as text): DuckDB has no `ALTER TYPE ... ADD VALUE`, and
//     widening an ENUM column in place (`ALTER COLUMN ... SET DATA TYPE ENUM(...)`) fails with a UINT8 cast error
//     in 1.1 — so neither SQLKit enum path can complete. `CREATE TYPE ... AS ENUM` still works as raw SQL.
//   - JSON sub-paths use `json_extract(col, '$."a"."b"')` (keys quoted), result is JSON text.
//   - `blob` stays `BLOB` (no `BYTEA` rename) and `TIMESTAMP` is NOT widened to `TIMESTAMPTZ`.
//   - No row-lock clauses (`FOR UPDATE` / `FOR SHARE` are not supported by DuckDB).
//   - No triggers (DuckDB has none), no `ALTER COLUMN ... SET DATA TYPE` batch quirks kept as Postgres.
public struct DuckDBDialect: SQLDialect {
    public init() {}

    public var name: String { "duckdb" }
    public var identifierQuote: any SQLExpression { SQLRaw(#"""#) }
    public var literalStringQuote: any SQLExpression { SQLRaw("'") }
    public static let autoIncrementSequence = "backendkit_autoincrement"
    public var supportsAutoIncrement: Bool { true }
    public var autoIncrementClause: any SQLExpression { SQLRaw("") }
    public var autoIncrementFunction: (any SQLExpression)? {
        SQLFunction("nextval", args: SQLLiteral.string(Self.autoIncrementSequence))
    }

    public func bindPlaceholder(at position: Int) -> any SQLExpression { SQLRaw("$\(position)") }
    public func literalBoolean(_ value: Bool) -> any SQLExpression { SQLRaw(value ? "true" : "false") }
    public var literalDefault: any SQLExpression { SQLRaw("DEFAULT") }
    public var supportsIfExists: Bool { true }
    public var enumSyntax: SQLEnumSyntax { .unsupported }
    public var supportsDropBehavior: Bool { true }
    public var supportsReturning: Bool { true }
    public var triggerSyntax: SQLTriggerSyntax { .init() }
    public var alterTableSyntax: SQLAlterTableSyntax {
        .init(
            alterColumnDefinitionClause: SQLRaw("ALTER COLUMN"),
            alterColumnDefinitionTypeKeyword: SQLRaw("SET DATA TYPE"),
            allowsBatch: false
        )
    }

    public var upsertSyntax: SQLUpsertSyntax { .standard }
    public var unionFeatures: SQLUnionFeatures {
        [.union, .unionAll, .intersect, .intersectAll, .except, .exceptAll, .explicitDistinct, .parenthesizedSubqueries]
    }

    public func nestedSubpathExpression(in column: any SQLExpression, for path: [String]) -> (any SQLExpression)? {
        guard !path.isEmpty else { return nil }
        // JSONPath with each key quoted, so a key containing `.` or a quote cannot change the path.
        let jsonPath = "$" + path.map { "." + "\"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined()
        return SQLFunction("json_extract", args: column, SQLLiteral.string(jsonPath))
    }
}
