# Testing

Tests run through kagami: `kagami test --all --strict` (every declared scope), or `kagami test --scope <scope> --strict`; scopes from `kagami test --scopes`. Never a bare `swift test`, except on Linux where kagami has no path yet: `.woodpecker/linux-build.yml` runs `swift test` there after `Scripts/install-libduckdb.sh` ([duckdb.md](duckdb.md)).

## Live Postgres

Every scope is green without a database. The live-Postgres tests (`BackendKitSQLTests`, `BackendKitPostgresTests`) SKIP unless `BACKENDKIT_LIVE_TESTS=1`. The switch is `LiveEnvKey.liveTests`, read through `LiveDatabase` (BackendKitTestSupport) from an injected `TypedEnvironment`. The connection is `PostgresConnectionConfig(environment:firstChoicePrefix: "SHIKKI_DB_")`, so `shikki-db` at `127.0.0.1:5433` works out of the box.

## Conventions

- Tests locate the package with CoreKit's `TestPackagePaths` and write only under `TestScratch` (the package's git-ignored `.tests/`). `FleetRatchetsTests` holds both rules, plus the `TaskDeadline` rule, across `Sources/` and `Tests/`.
- The reconnect ladder (`ReconnectPolicy`) is driven by CoreKit's `FakeDrainClock`: no test sleeps in real time.
- The kagami scope floors in `.kagami/scopes.override.toml` are the counts that pass with no server.
