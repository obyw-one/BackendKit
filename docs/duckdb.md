# DuckDB in BackendKit

`BackendKitDuckDB` runs on the DuckDB binding each platform can actually build:

| platform             | binding                                                  | DuckDB version                      |
| -------------------- | -------------------------------------------------------- | ----------------------------------- |
| macOS, iOS, tvOS, visionOS | [duckdb-swift](https://github.com/duckdb/duckdb-swift), pinned exactly | `2.1.0-dev84836` (a dev snapshot)   |
| Linux (amd64, arm64) | the official `libduckdb` through its C API               | `v2.0.0` (stable release)           |

The two sides are **not on the same DuckDB version**, and that is deliberate and recorded: duckdb-swift has no stable release for DuckDB 2.x (its newest tags are dev snapshots; the newest stable, 1.1.3, is DuckDB 1.1) and it does not compile on Linux (it reads `Foundation.Decimal`'s `_mantissa` / `_length`, which Linux's Foundation does not expose). BackendKit does not fork, vendor or patch it. `DuckDBVersionPins` is the one place that records both versions, and `DuckDBVersionPinTests` fails if `Package.swift`, `Scripts/libduckdb.lock` or the library that actually loads disagrees with it, so a bump is deliberate on both sides. Move Apple to a stable duckdb-swift tag as soon as one exists for DuckDB 2.x.

One facade sits in front of the two bindings (`DuckDBDriverProtocol`, internal): the host, the bind encoder, the value decoder and the dialect are one implementation, and one behaviour suite (`DuckDBTypeBehaviourTests`, `DuckDBFailureBehaviourTests`, `DuckDBRepositoryTypesTests`, the SQLKit conformance tests) runs unchanged against whichever driver the platform compiles. What it pins down, on both:

- Every failure DuckDB reports is thrown as `DuckDBSQLError.engine(<DuckDB's own text>)`.
- A result column of a type that is not decoded throws `DuckDBSQLError.unsupportedColumnType`, also when no row comes back; it is never returned as NULL. Decoded: BOOLEAN, TINYINT to BIGINT, UTINYINT to UBIGINT, HUGEINT and UHUGEINT (as decimal text), FLOAT, DOUBLE, DECIMAL (exact, 38 digits), VARCHAR, BLOB, UUID, DATE, TIMESTAMP in every unit and with time zone. Not decoded: TIME, TIMETZ, INTERVAL, ENUM, LIST, ARRAY, STRUCT, MAP, UNION, BIT; `CAST(x AS VARCHAR)` in the query is the way through.
- A `Decimal` that DuckDB's DECIMAL(38, s) cannot hold (more than 38 digits, a scale above 38, NaN) is refused, never rounded. A zero decimal binds as the integer 0.
- `DuckDBSQLHost.shutdown()` releases the database at once, so a file database can be reopened straight away.

## DuckDB on Linux

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

## Why Linux does not use duckdb-swift

It does not compile there. Measured 2026-11-07 on swift:6.3-jammy (arm64): `Sources/DuckDB/Internal/CTypeUtilities.swift:283-287` and `Extensions/Decimal+IntHuge.swift:42,64` build and read `Foundation.Decimal` through its `_mantissa` / `_length` members, which Linux's Foundation does not expose ("'_mantissa' is inaccessible due to 'internal' protection level"). The pinned 2.1.0-dev84836 is upstream `main`; the newest 1.x dev tag (1.6.0-dev11145) and the newest 1.x stable (1.1.3) fail with the same errors. BackendKit does not fork, vendor or patch duckdb-swift.

## How the manifest wires it

- `CDuckDB` is a system library found through pkg-config (`duckdb.pc`). It is not vendored and no binary is committed. It is declared only when the manifest is evaluated on Linux: SwiftPM resolves a system library's pkg-config file whether or not the build uses it, so declaring it on Apple hosts would print "couldn't find pc file for duckdb" on every macOS and Xcode build of every consumer.
- `duckDBSwiftPlatforms` (macOS, iOS, tvOS, visionOS) selects duckdb-swift; `libDuckDBPlatforms` (Linux) selects `CDuckDB`. The driver files choose with `#if os(Linux)`, so there is no flag to keep in step.
- `DuckDBVersionPinTests` fails if `Package.swift`, `Scripts/libduckdb.lock` or the loaded library disagrees with `DuckDBVersionPins`.
