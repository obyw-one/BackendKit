# BackendKit

The engine-agnostic database connection seam of the fleet, one product per engine, on
[CoreKit](https://github.com/FJ-Studios/CoreKit)'s `RepositoryProtocol` and `Container`.

| product | contents | driver |
|---|---|---|
| `BackendKitCore` | `DBConnectionConfiguring`, `PostgresConnectionConfig(environment:firstChoicePrefix:)`, `ConnectionPolicy`, `ConnectionInjectionRatchet` | none |
| `BackendKitPostgres` | `PostgresClientHost`, `PostgresClient.Configuration.make(connection:policy:)`, `PostgresRepository<ID, Model>` | postgres-nio |
| `BackendKitDuckDB` | reserved — added when a consumer exists | duckdb-swift |

Rules: one `connection:` value, injected once (the ratchet helper enforces it in every consumer);
the host sleeps through `CoreKit.TaskDeadline`, never a clock-based `Task.sleep`;
BackendKit depends on CoreKit only — never on NetKit, never on ShiKit.

Spec: `backendkit-connection-seam-and-postgres-product-2026-09-12` (b7e2d4f6). Owner: obyw-one.
