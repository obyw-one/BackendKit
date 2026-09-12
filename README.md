# BackendKit

The engine-agnostic database connection seam of the fleet, one product per engine, on
[CoreKit](https://github.com/FJ-Studios/CoreKit)'s `RepositoryProtocol` and `Container`.

| product              | contents                                                                                                                         | driver         |
|----------------------|----------------------------------------------------------------------------------------------------------------------------------|----------------|
| `BackendKitCore`     | `DBConnectionConfiguring`, `PostgresConnectionConfig(environment:firstChoicePrefix:)`, `ConnectionPolicy`, `ConnectionInjectionRatchet` | none           |
| `BackendKitPostgres` | `PostgresClientHost`, `PostgresClient.Configuration.make(connection:policy:)`, `PostgresRepository<ID, Model>`                    | postgres-nio   |
| `BackendKitLibsql`   | reserved — the libSQL/SQLite product, added in W3 by absorbing shikki-io/DataKit                                                  | libsql-swift   |
| `BackendKitDuckDB`   | reserved — added when a consumer exists                                                                                          | duckdb-swift   |

Rules of the seam:

- **One `connection:` value, injected once.** A store or client host takes ONE `connection: any DBConnectionConfiguring` — never five scalars each defaulting to a fresh resolver, and never rebuilds a config in its body. `ConnectionInjectionRatchet.scan(sourcesRoot:)` enforces this in every consumer's tests.
- **The host sleeps through `CoreKit.TaskDeadline`, never a clock-based `Task.sleep`.** The clock-based shape aborts the Swift 6 runtime under cancellation in a task group.
- **BackendKit depends on CoreKit only** — never on NetKit, never on ShiKit. `BackendKitCore` carries no driver; each product pulls its own.
- **`psql` invocation is the seam's too.** `psqlConnectionArguments` on the protocol renders the canonical `-h/-p/-U/-d --no-psqlrc` vector; the password is left to `PGPASSWORD` so it never lands in a process listing.

## Adding a consumer

```swift
import BackendKitCore
import BackendKitPostgres
import CoreKit

let connection = PostgresConnectionConfig(
    environment: ProcessInfo.processInfo.environment,
    firstChoicePrefix: "SIGMA_DB_"  // optional consumer prefix
)
let host = PostgresClientHost(connection: connection, policy: .shikki)
let container = Container(name: "sigma")
container.register(PostgresRepository<UUID, MyModel>.self) { _ in
    PostgresRepository(client: host.client, table: "my_records")
}
```

That is the full contract — one config, one host, one repository. Nothing else imports postgres-nio.

## Testing

- `swift test` — green without a database (T-01…T-03, T-05).
- `BACKENDKIT_LIVE_TESTS=1 swift test` — exercises `PostgresRepositoryLiveTests` against a running Postgres (T-04).
- The Postgres tests read their connection through `PostgresConnectionConfig(environment:firstChoicePrefix: "SHIKKI_DB_")` so `shikki-db` at `127.0.0.1:5433` works out of the box.

## Spec & owner

Spec: `backendkit-connection-seam-and-postgres-product-2026-09-12` (b7e2d4f6). Owner: obyw-one. Depends on CoreKit ≥ 0.9.0 (`TaskDeadline`, `RepositoryProtocol`, `Container`).
