// MARK: - Off macOS and Linux

//
// BackendKitPostgres links PostgresNIO and PostgresKit, which the package only depends on for macOS and Linux
// (`serverPlatforms` in Package.swift). On every other platform the target compiles to this file alone, so
// `import BackendKitPostgres` is accepted but the first USE of a Postgres type is a compile error that says why,
// instead of a missing-module cascade or a runtime failure. The attribute messages are literals on purpose.

#if !BACKENDKIT_POSTGRES

import BackendKitCore

@available(*, unavailable, message: "BackendKitPostgres is macOS and Linux only; use BackendKitSQLite on iOS and tvOS.")
public final class PostgresClientHost {
    @available(*, unavailable, message: "BackendKitPostgres is macOS and Linux only; use BackendKitSQLite on iOS and tvOS.")
    public init(connection: any DBConnectionConfiguring) { fatalError() }
}

@available(*, unavailable, message: "BackendKitPostgres is macOS and Linux only; use BackendKitSQLite on iOS and tvOS.")
public final class PostgresSQLHost {
    @available(*, unavailable, message: "BackendKitPostgres is macOS and Linux only; use BackendKitSQLite on iOS and tvOS.")
    public init(connection: any DBConnectionConfiguring) { fatalError() }
}

@available(*, unavailable, message: "BackendKitPostgres is macOS and Linux only; use BackendKitSQLite on iOS and tvOS.")
public actor PostgresRepository<ID, Model> {}

#endif
