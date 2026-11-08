# Platforms

`platforms:` in `Package.swift` declares Apple minimums only (macOS 14, iOS 17, tvOS 18, visionOS 1); it does not exclude Linux, nor a platform per target. Floors follow CoreKit 0.13.0 (iOS 17 / macOS 14; tvOS and visionOS are not declared by CoreKit, so SwiftPM builds it at its oldest supported version there). Every engine dependency declares lower floors. CoreKit's core is Linux-clean: SwiftUI lives in the Apple-only `CoreKitUI` product, which BackendKit never imports.

Every product is offered on macOS, iOS, tvOS, visionOS and Linux with the same public API. The only per-platform difference is what `BackendKitDuckDB` is built on ([duckdb.md](duckdb.md)).

| product                                   | macOS, iOS, tvOS, visionOS | Linux              |
| ----------------------------------------- | -------------------------- | ------------------ |
| `BackendKitCore`, `BackendKitSQL`, `BackendKitSQLite` | yes            | yes                |
| `BackendKitPostgres`                      | yes                        | yes                |
| `BackendKitDuckDB`                        | duckdb-swift               | libduckdb C API    |

`BackendKitSQL` is engine-neutral (SQLKit only, no driver); NetKit's wire layer never imports it.

## Measured

Postgres on iOS and tvOS (2026-11-07): the live Codable round-trip (`PostgresRepository`, over `PostgresClientHost`) and the live `SQLRepository` round-trip (over `PostgresSQLHost`) connected to a real Postgres 17 (SCRAM auth), wrote and read back on an iOS 26.5 Simulator and a tvOS 26.5 Simulator through `xcodebuild test`; the server's own log shows the statements. A Simulator is not a device (it shares the Mac's network stack and permissions), so a run on hardware is still the consumer's to confirm. visionOS is built (`generic/platform=visionOS Simulator`) in the macOS gate; see the status note at the end of this file.

## Gates

- `.woodpecker/linux-build.yml`: build and test on Linux.
- `.woodpecker/macos-gate.yml` (maintainer's Mac only): `kagami test --all --strict`, then `xcodebuild build` for macOS, iOS Simulator, tvOS Simulator and visionOS Simulator.
