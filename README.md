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

| product                                               | macOS | iOS / tvOS | Linux |
| ----------------------------------------------------- | :---: | :--------: | :---: |
| `BackendKitCore`, `BackendKitSQL`, `BackendKitSQLite` | yes   | yes        | yes   |
| `BackendKitPostgres` (PostgresNIO, PostgresKit)       | yes   | yes        | yes   |
| `BackendKitDuckDB`                                    | yes   | yes        | yes   |

Every product is offered on every platform, with the same public API. `platforms:` in `Package.swift` declares Apple minimums only; what each product is built on is declared once, in the manifest's "Platform split". Postgres on iOS and tvOS was measured against a live server on Simulators (a Simulator is not a device). `.woodpecker/linux-build.yml` builds and tests the package on Linux.

## DuckDB: one API, two bindings

`BackendKitDuckDB` runs on the DuckDB binding each platform can actually build:

| platform             | binding                                                  | DuckDB version                      |
| -------------------- | -------------------------------------------------------- | ----------------------------------- |
| macOS, iOS, tvOS     | [duckdb-swift](https://github.com/duckdb/duckdb-swift), pinned exactly | `2.1.0-dev84836` (a dev snapshot)   |
| Linux (amd64, arm64) | the official `libduckdb` through its C API               | `v2.0.0` (stable release)           |

The two sides are **not on the same DuckDB version**, and that is deliberate and recorded: duckdb-swift has no stable release for DuckDB 2.x (its newest tags are dev snapshots; the newest stable, 1.1.3, is DuckDB 1.1) and it does not compile on Linux (it reads `Foundation.Decimal`'s `_mantissa` / `_length`, which Linux's Foundation does not expose). BackendKit does not fork, vendor or patch it. `DuckDBVersionPins` is the one place that records both versions, and `DuckDBVersionPinTests` fails if `Package.swift`, `Scripts/libduckdb.lock` or the library that actually loads disagrees with it, so a bump is deliberate on both sides. Move Apple to a stable duckdb-swift tag as soon as one exists for DuckDB 2.x.

One facade sits in front of the two bindings (`DuckDBDriverProtocol`, internal): the host, the bind encoder, the value decoder and the dialect are one implementation, and one behaviour suite (`DuckDBTypeBehaviourTests`, `DuckDBFailureBehaviourTests`, `DuckDBRepositoryTypesTests`, the SQLKit conformance tests) runs unchanged against whichever driver the platform compiles. What it pins down, on both:

- Every failure DuckDB reports is thrown as `DuckDBSQLError.engine(<DuckDB's own text>)`.
- A result column of a type that is not decoded throws `DuckDBSQLError.unsupportedColumnType`, also when no row comes back; it is never returned as NULL. Decoded: BOOLEAN, TINYINT to BIGINT, UTINYINT to UBIGINT, HUGEINT and UHUGEINT (as decimal text), FLOAT, DOUBLE, DECIMAL (exact, 38 digits), VARCHAR, BLOB, UUID, DATE, TIMESTAMP in every unit and with time zone. Not decoded: TIME, TIMETZ, INTERVAL, ENUM, LIST, ARRAY, STRUCT, MAP, UNION, BIT; `CAST(x AS VARCHAR)` in the query is the way through.
- A `Decimal` that DuckDB's DECIMAL(38, s) cannot hold (more than 38 digits, a scale above 38, NaN) is refused, never rounded. A zero decimal binds as the integer 0.
- `DuckDBSQLHost.shutdown()` releases the database at once, so a file database can be reopened straight away.

### DuckDB on Linux

Nothing is committed to this repository and SwiftPM downloads no binary: the Linux build links an installed copy of the official release, pinned and verified.

1. **Install the library** (a build machine, a CI job, or a Dockerfile layer):

   ```sh
   Scripts/install-libduckdb.sh              # to /usr/local (as root; also runs ldconfig)
   Scripts/install-libduckdb.sh "$HOME/.local/duckdb"   # or to a prefix of your own
   ```

   The script reads `Scripts/libduckdb.lock` (exact version `v2.0.0`, one sha256 per architecture), picks amd64 or arm64 from `uname -m`, downloads `duckdb-shared-libs-linux-<arch>.tar.gz` from DuckDB's GitHub release with curl, wget or python3 (whichever exists), and **compares its sha256 with the pinned one before extracting anything**. A failed download, a digest mismatch, an unknown architecture or a missing file exits non-zero and installs nothing. `LIBDUCKDB_ARCHIVE=<file>` installs from an archive you already have (offline builds); it is verified against the same digest. It installs `lib/libduckdb.so`, `include/duckdb.h` and `lib/pkgconfig/duckdb.pc` under the prefix.

2. **Build**: SwiftPM finds the library through pkg-config. Under `/usr/local` nothing else is needed; under another prefix:

   ```sh
   PKG_CONFIG_PATH="$HOME/.local/duckdb/lib/pkgconfig" swift build
   ```

   If `duckdb.h` cannot be found, the build stops with an error that says to run the script. A consumer that does not use `BackendKitDuckDB` on Linux never needs the library: SwiftPM only builds the targets a product reaches.

3. **Run**: a server that uses `BackendKitDuckDB` needs **`libduckdb.so` (v2.0.0, about 100 MB) in the dynamic loader's path** on the machine that runs it, and nothing else from DuckDB. Put it under a system prefix and run `ldconfig`, or set `LD_LIBRARY_PATH=<prefix>/lib` (SwiftPM refuses an rpath coming from pkg-config, so a custom prefix needs the variable). The library is linked against glibc 2.25 or newer and `libstdc++.so.6` (GLIBCXX 3.4.22, from GCC 6), `libgcc_s`, `libm`; Swift's own runtime needs libstdc++ as well, so an image that runs Swift programs has them. Alpine/musl is not covered by this script (DuckDB publishes separate musl libraries). A container image needs the same step:

   ```dockerfile
   COPY Scripts/install-libduckdb.sh Scripts/libduckdb.lock /tmp/duckdb/Scripts/
   RUN sh /tmp/duckdb/Scripts/install-libduckdb.sh /usr/local && rm -r /tmp/duckdb
   ```

   A missing library fails at process start (the loader cannot find `libduckdb.so`), not on the first query.

Cross-compiling `BackendKitDuckDB` for Linux from a Mac is not supported (the Linux-only `CDuckDB` target is declared only when the manifest is evaluated on Linux, so Apple builds never look for the library); every other product cross-compiles as before.

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

- Every scope is green without a database. `BackendKitSQLTests` and `BackendKitPostgresTests` each carry live-Postgres tests that SKIP unless `BACKENDKIT_LIVE_TESTS=1` is set.
- `BACKENDKIT_LIVE_TESTS=1` exercises them against a running Postgres. The Postgres tests read their connection through `PostgresConnectionConfig(environment:firstChoicePrefix: "SHIKKI_DB_")` so `shikki-db` at `127.0.0.1:5433` works out of the box.
- Tests locate the package with CoreKit's `TestPackagePaths` and write only under `TestScratch` (the package's own git-ignored `.tests/`); `FleetRatchetsTests` holds both rules, plus the `TaskDeadline` rule, across `Sources/` and `Tests/`.

## Spec & owner

Spec: `backendkit-connection-seam-and-postgres-product-2026-09-12` (b7e2d4f6). Owner: obyw-one. Depends on CoreKit ≥ 0.13.0 (`TypedEnvironment`, `TaskDeadline`, `RepositoryProtocol`, `Container`, and `CoreKitTestSupport` in the tests).
