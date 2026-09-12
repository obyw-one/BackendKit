import CoreKit
import Foundation
import Logging

// MARK: - PostgresEnvKey

/// libpq's connection variables — the ONLY environment names this kit reads
/// on its own behalf, declared once (CoreKit `EnvironmentKey`, BackendKit #2
/// review: no raw `environment["…"]` anywhere). Shikki's spec 9d2f6b8e keeps
/// these as class-A process contract: set by the operator / spawner, read
/// here, never chosen by the kit.
public enum PostgresEnvKey: String, EnvironmentKey {
    case host = "PGHOST"
    case port = "PGPORT"
    case user = "PGUSER"
    case database = "PGDATABASE"
    case password = "PGPASSWORD"
}

// MARK: - ConnectionKeySuffix

/// The consumer-prefixed spelling of the same five fields — `SHIKKI_DB_` +
/// `HOST` … The prefix is the consumer's data; the suffix stays a declared
/// key so the resolver never assembles a name from a string literal.
public enum ConnectionKeySuffix: String, EnvironmentKey {
    case host = "HOST"
    case port = "PORT"
    case user = "USER"
    case database = "NAME"
    case password = "PASSWORD"
}

// MARK: - PostgresConnectionConfig

//
// The kit's libpq resolver (spec b7e2d4f6, BR-BKT-02). Reads the standard
// `PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE` variables after an optional
// consumer prefix — shikki passes `SHIKKI_DB_`, sigma-analytics has no prefix,
// a future consumer picks its own without ever re-implementing this resolver.
//
// The prefix mapping uses the shikki-style suffixes (HOST/PORT/USER/NAME/
// PASSWORD) so a `SHIKKI_DB_NAME` value flows into `database` — libpq's own
// key for the same field is `PGDATABASE`. That asymmetry is by design: the
// prefix is the consumer's naming, libpq is libpq's.
//
// The environment arrives as a CoreKit `TypedEnvironment` snapshot: the
// caller decides where it comes from (`.current()` at a process edge, a
// settings registry's env-override pairs in shikki after spec 9d2f6b8e W3,
// a literal in tests). The resolver never touches `ProcessInfo` itself.
//
// Malformed `port` values emit ONE warning naming the offending key and fall
// through to the next choice — the connection still resolves rather than
// crashing at boot.

public struct PostgresConnectionConfig: DBConnectionConfiguring, Sendable {
    public let host: String
    public let port: Int
    public let user: String
    public let database: String
    public let password: String?

    /// libpq's canonical defaults — used when nothing else resolves.
    /// A consumer that wants a different default (e.g. shikki's port 5433)
    /// wraps this type or supplies its own explicit init.
    public static let defaultHost = "localhost"
    public static let defaultPort = 5432
    public static let defaultUser = "postgres"

    /// Explicit connection — for tests and for callers that received the
    /// parameters from a verb or a settings file; production code that
    /// honours libpq uses `init(environment:)`.
    public init(
        host: String,
        port: Int,
        user: String,
        database: String,
        password: String?
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.database = database
        self.password = password
    }

    /// Resolve a connection from a typed environment snapshot.
    ///
    /// - Parameters:
    ///   - environment: the snapshot to read — `.current()` at a process
    ///     edge, or whatever the consumer assembled. There is no default:
    ///     reading the process env is the caller's visible decision.
    ///   - firstChoicePrefix: an optional consumer prefix (e.g. `"SHIKKI_DB_"`)
    ///     whose `<prefix>HOST/PORT/USER/NAME/PASSWORD` keys are tried BEFORE
    ///     libpq's `PGHOST/PGPORT/PGUSER/PGDATABASE/PGPASSWORD`.
    ///   - logger: where malformed-port warnings go; default label
    ///     `"backendkit.postgres.config"`. Injected for hermetic tests.
    public init(
        environment env: TypedEnvironment,
        firstChoicePrefix: String? = nil,
        logger: Logger = Logger(label: "backendkit.postgres.config")
    ) {
        host = Self.resolve(.host, libpq: .host, env: env, prefix: firstChoicePrefix) ?? Self.defaultHost
        port = Self.resolvePort(env: env, prefix: firstChoicePrefix, logger: logger)
        user = Self.resolve(.user, libpq: .user, env: env, prefix: firstChoicePrefix) ?? Self.defaultUser
        // libpq's convention: PGDATABASE unset → same as user.
        database = Self.resolve(.database, libpq: .database, env: env, prefix: firstChoicePrefix) ?? user
        password = Self.resolve(.password, libpq: .password, env: env, prefix: firstChoicePrefix)
    }

    /// Convenience for tests and spawners holding a plain dictionary — wraps
    /// it in a `TypedEnvironment` and resolves exactly as above.
    public init(
        environment variables: [String: String],
        firstChoicePrefix: String? = nil,
        logger: Logger = Logger(label: "backendkit.postgres.config")
    ) {
        self.init(environment: TypedEnvironment(variables), firstChoicePrefix: firstChoicePrefix, logger: logger)
    }

    // MARK: - Private helpers

    private static func resolve(
        _ suffix: ConnectionKeySuffix,
        libpq key: PostgresEnvKey,
        env: TypedEnvironment,
        prefix: String?
    ) -> String? {
        if let prefix, let value = env[suffix, prefix: prefix] {
            return value
        }
        return env[key]
    }

    private static func resolvePort(
        env: TypedEnvironment,
        prefix: String?,
        logger: Logger
    ) -> Int {
        if let prefix, let raw = env[ConnectionKeySuffix.port, prefix: prefix] {
            if let parsed = Int(raw) {
                return parsed
            }
            logger.warning(
                "malformed port in \(prefix)\(ConnectionKeySuffix.port.rawValue)=\(raw) — falling through to libpq PGPORT / default \(defaultPort)"
            )
        }
        if let raw = env[PostgresEnvKey.port] {
            if let parsed = Int(raw) {
                return parsed
            }
            logger.warning("malformed port in PGPORT=\(raw) — falling back to default \(defaultPort)")
        }
        return defaultPort
    }
}
