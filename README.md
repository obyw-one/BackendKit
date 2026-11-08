# BackendKit

The engine-agnostic database connection seam of the fleet, one product per engine, on
[CoreKit](https://github.com/FJ-Studios/CoreKit)'s `RepositoryProtocol` and `Container`.

| product              | contents                                                                                                                                | driver       |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| `BackendKitCore`     | `DBConnectionConfiguring`, `PostgresConnectionConfig(environment:firstChoicePrefix:)`, `ConnectionPolicy`, `ConnectionInjectionRatchet` | none         |
| `BackendKitPostgres` | `PostgresClientHost`, `PostgresClient.Configuration.make(connection:policy:)`, `PostgresRepository<ID, Model>`, `PostgresSQLHost`       | postgres-nio |
| `BackendKitSQL`      | `SQLRepository<ID, Model>` — one typed, parameter-binding repository over any SQLKit `SQLDatabase` (engine-neutral)                      | SQLKit       |
| `BackendKitSQLite`   | `SQLiteSQLHost` — file / in-memory SQLite engine for `SQLRepository`                                                                    | sqlite-kit   |
| `BackendKitDuckDB`   | `DuckDBSQLHost` — embedded, single-writer DuckDB engine for `SQLRepository`                                                             | duckdb-swift (Apple), libduckdb C API (Linux) |

## Platforms

| product                                               | macOS | iOS / tvOS / visionOS | Linux |
| ----------------------------------------------------- | :---: | :-------------------: | :---: |
| `BackendKitCore`, `BackendKitSQL`, `BackendKitSQLite` | yes   | yes                   | yes   |
| `BackendKitPostgres` (PostgresNIO, PostgresKit)       | yes   | yes                   | yes   |
| `BackendKitDuckDB`                                    | yes   | yes                   | yes   |

Every product is offered on every platform with the same public API: if it works on iOS it works on visionOS. Floors: macOS 14, iOS 17, tvOS 18, visionOS 1. Rationale, what was measured where, and the gates: [docs/platforms.md](docs/platforms.md).

## DuckDB

One API, two bindings: duckdb-swift on Apple (macOS, iOS, tvOS, visionOS), the official `libduckdb` C API on Linux. Versions, the facade, the Linux install and the runtime requirements: [docs/duckdb.md](docs/duckdb.md).

Rules of the seam:

- **One `connection:` value, injected once.** A store or client host takes ONE `connection: any DBConnectionConfiguring` — never five scalars each defaulting to a fresh resolver, and never rebuilds a config in its body. `ConnectionInjectionRatchet.scan(sourcesRoot:)` enforces this in every consumer's tests.
- **The host sleeps through `CoreKit.TaskDeadline`, never a clock-based `Task.sleep`.** The clock-based shape aborts the Swift 6 runtime under cancellation in a task group.
- **BackendKit depends on CoreKit only** — never on NetKit, never on ShiKit. `BackendKitCore` carries no driver; each product pulls its own.
- **`psql` invocation is the seam's too.** `psqlConnectionArguments` on the protocol renders the canonical `-h/-p/-U/-d --no-psqlrc` vector; the password is left to `PGPASSWORD` so it never lands in a process listing.

## Adding a consumer

The process environment is read in ONE place in the fleet, `TypedEnvironment.current()`; the resolver takes the snapshot, it never reads the process itself.

```swift
import BackendKitCore
import BackendKitPostgres
import BackendKitSQL
import CoreKit

struct Note: Codable, Sendable { let id: UUID; let title: String }

let connection = PostgresConnectionConfig(
    environment: TypedEnvironment.current(),
    firstChoicePrefix: "SIGMA_DB_"  // optional consumer prefix
)
let host = PostgresSQLHost(connection: connection)

// Register the PROTOCOL, never the engine: the environment picks the implementation
// (SQL in production, CoreKit's `InMemoryRepository` in mock) and the consumer never changes.
struct NotesAssembly: DIAssembly {
    let database: any SQLDatabase
    func assemble(container: Container, environment: DIEnvironment) {
        switch environment {
        case .production:
            container.register((any RepositoryProtocol<UUID, Note>).self) { [database] _ in
                SQLRepository<UUID, Note>(database: database, table: "notes")
            }
        case .mock:
            container.register((any RepositoryProtocol<UUID, Note>).self) { _ in InMemoryRepository<UUID, Note>() }
        }
    }
}
DI.configure(for: .production, assemblies: [NotesAssembly(database: host.database)])

// Anywhere downstream: `@Resolve var notes: any RepositoryProtocol<UUID, Note>`
```

That is the full contract — one config, one host, one repository. Nothing else imports postgres-nio. A JSONB-per-row store is `PostgresRepository(client: PostgresClientHost(connection:).client, table:)`, registered the same way.

## Testing

Tests run through kagami (`kagami test --scope <scope> --strict`, scopes from `kagami test --scopes`), never a bare `swift test`. The one exception is Linux, where kagami has no path yet: `.woodpecker/linux-build.yml` runs `swift test` there (after `Scripts/install-libduckdb.sh`, see above).

- Every scope is green without a database; the live-Postgres tests SKIP unless `BACKENDKIT_LIVE_TESTS=1` is set. Details: [docs/testing.md](docs/testing.md).
- Tests locate the package with CoreKit's `TestPackagePaths` and write only under `TestScratch` (the package's own git-ignored `.tests/`); `FleetRatchetsTests` holds both rules, plus the `TaskDeadline` rule, across `Sources/` and `Tests/`.

## Spec & owner

Spec: `backendkit-connection-seam-and-postgres-product-2026-09-12` (b7e2d4f6). Owner: obyw-one. Depends on CoreKit ≥ 0.13.0 (`TypedEnvironment`, `TaskDeadline`, `RepositoryProtocol`, `Container`, and `CoreKitTestSupport` in the tests).
