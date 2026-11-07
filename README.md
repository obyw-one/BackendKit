# BackendKit

The engine-agnostic database connection seam of the fleet, one product per engine, on
[CoreKit](https://github.com/FJ-Studios/CoreKit)'s `RepositoryProtocol` and `Container`.

| product              | contents                                                                                                                                | driver       |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| `BackendKitCore`     | `DBConnectionConfiguring`, `PostgresConnectionConfig(environment:firstChoicePrefix:)`, `ConnectionPolicy`, `ConnectionInjectionRatchet` | none         |
| `BackendKitPostgres` | `PostgresClientHost`, `PostgresClient.Configuration.make(connection:policy:)`, `PostgresRepository<ID, Model>`, `PostgresSQLHost`       | postgres-nio |
| `BackendKitSQL`      | `SQLRepository<ID, Model>` — one typed, parameter-binding repository over any SQLKit `SQLDatabase` (engine-neutral)                      | SQLKit       |
| `BackendKitSQLite`   | `SQLiteSQLHost` — file / in-memory SQLite engine for `SQLRepository`                                                                    | sqlite-kit   |
| `BackendKitDuckDB`   | `DuckDBSQLHost` — embedded, single-writer DuckDB engine for `SQLRepository`                                                             | duckdb-swift |

## Platforms

| product                                          | macOS | iOS / tvOS | Linux |
| ------------------------------------------------ | :---: | :--------: | :---: |
| `BackendKitCore`, `BackendKitSQL`, `BackendKitSQLite` | yes   | yes        | yes   |
| `BackendKitPostgres` (PostgresNIO, PostgresKit)  | yes   | yes        | yes   |
| `BackendKitDuckDB` (duckdb-swift)                | yes   | yes        | no    |

`platforms:` in `Package.swift` declares Apple minimums only; which product exists where is declared once, in the manifest's "Platform split", through a conditional target dependency and a matching compilation flag. Off its platforms a product is an empty module whose types are `unavailable` with a message that says why, so using a DuckDB type on Linux is a compile error. DuckDB is not offered on Linux because duckdb-swift does not compile there (it reads `Foundation.Decimal`'s `_mantissa` / `_length`, which Linux does not expose); the manifest records the failure. Postgres on iOS and tvOS was measured against a live server on Simulators (a Simulator is not a device). `.woodpecker/linux-build.yml` builds and tests the package on Linux.

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

Tests run through kagami (`kagami test --scope <scope> --strict`, scopes from `kagami test --scopes`), never a bare `swift test`.

- Every scope is green without a database. `BackendKitSQLTests` and `BackendKitPostgresTests` each carry live-Postgres tests that SKIP unless `BACKENDKIT_LIVE_TESTS=1` is set.
- `BACKENDKIT_LIVE_TESTS=1` exercises them against a running Postgres. The Postgres tests read their connection through `PostgresConnectionConfig(environment:firstChoicePrefix: "SHIKKI_DB_")` so `shikki-db` at `127.0.0.1:5433` works out of the box.
- Tests locate the package with CoreKit's `TestPackagePaths` and write only under `TestScratch` (the package's own git-ignored `.tests/`); `FleetRatchetsTests` holds both rules, plus the `TaskDeadline` rule, across `Sources/` and `Tests/`.

## Spec & owner

Spec: `backendkit-connection-seam-and-postgres-product-2026-09-12` (b7e2d4f6). Owner: obyw-one. Depends on CoreKit ≥ 0.12.0 (`TypedEnvironment`, `TaskDeadline`, `RepositoryProtocol`, `Container`, and `CoreKitTestSupport` in the tests).
