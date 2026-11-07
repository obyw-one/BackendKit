import BackendKitCore
import PostgresNIO

// MARK: - PostgresClient.Configuration.make(connection:policy:)

//
// The ONE way BackendKit configures a `PostgresClient` (spec b7e2d4f6, BR-BKT-03).
// Extracted from shikki's `PostgresClient.Configuration.shikki(connection:)`
// (`PostgresClientConfiguration+Shikki.swift`) so every consumer picks the
// same shape: TLS disabled (local Postgres, the fleet's data path), pool
// timers picked from the injected `ConnectionPolicy` — never left at
// postgres-nio's defaults.
//
// A caller reads:
//
//     let config = PostgresClient.Configuration.make(
//         connection: PostgresConnectionConfig(environment: env),
//         policy: .shikki
//     )
//     let client = PostgresClient(configuration: config)
//
// Rebuilding the fields by hand is the exact shape PR #1669 fixed.

public extension PostgresClient.Configuration {
    /// The kit's canonical factory. Reads five scalars off the `connection:`
    /// value, sets `keepAliveBehavior` and `connectionIdleTimeout` from the
    /// `policy:` value, and never touches the process environment itself.
    static func make(
        connection: any DBConnectionConfiguring,
        policy: ConnectionPolicy = .shikki
    ) -> PostgresClient.Configuration {
        var config = PostgresClient.Configuration(
            host: connection.host,
            port: connection.port,
            username: connection.user,
            password: connection.password,
            database: connection.database,
            tls: .disable
        )
        if let keepAlive = policy.keepAlive {
            config.options.keepAliveBehavior = .init(frequency: keepAlive)
        } else {
            config.options.keepAliveBehavior = nil
        }
        config.options.connectionIdleTimeout = policy.idle
        return config
    }
}
