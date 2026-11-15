@preconcurrency import AsyncKit
import BackendKitCore
import BackendKitSQL
import Logging
import NIOPosix
import PostgresKit
import SQLKit

// MARK: - PostgresSQLHost

//
// The Postgres engine for `SQLRepository` (spec b4f8c3a1, BR-SQL-04/07): PostgresKit's
// connection pool, exposed as an `any SQLDatabase`. This is the ONE place the NIO
// boundary is owned — the event-loop group and the pool are created here and torn
// down by the async `shutdown()`. Everything public is `async`; no EventLoopFuture
// leaves BackendKit. Pass `database` to `SQLRepository(database:table:)`.

public actor PostgresSQLHost {
    // `pool` is AsyncKit's `EventLoopGroupConnectionPool`, which upstream does not declare `Sendable` (it guards
    // its own state with an internal `NIOLock`). BackendKit touches it only from `shutdown()`, so it lives behind
    // this actor's isolation instead of behind an `@unchecked Sendable` on the host. Queries never come through
    // the actor: they go through `database`, SQLKit's `Sendable` handle onto the same pool, which is `nonisolated`
    // so `host.database` stays a synchronous read.
    private let group: MultiThreadedEventLoopGroup
    private let pool: EventLoopGroupConnectionPool<PostgresConnectionSource>

    /// The injected engine: hand this to `SQLRepository`.
    nonisolated public let database: any SQLDatabase

    public init(
        connection: any DBConnectionConfiguring,
        maxConnectionsPerEventLoop: Int = 1,
        logger: Logger = Logger(label: "backendkit.postgres.sql")
    ) {
        let configuration = SQLPostgresConfiguration(
            hostname: connection.host,
            port: connection.port,
            username: connection.user,
            password: connection.password,
            database: connection.database,
            tls: .disable
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: max(1, maxConnectionsPerEventLoop))
        let pool = EventLoopGroupConnectionPool(
            source: PostgresConnectionSource(sqlConfiguration: configuration),
            maxConnectionsPerEventLoop: maxConnectionsPerEventLoop,
            logger: logger,
            on: group
        )
        self.group = group
        self.pool = pool
        database = pool.database(logger: logger).sql()
    }

    /// Close the pool, then the event-loop group. Call once, before the host is dropped.
    public func shutdown() async throws {
        try await pool.shutdownAsync()
        try await group.shutdownGracefully()
    }
}
