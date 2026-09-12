import Foundation
import Logging

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
    /// parameters from a verb; production code uses `init(environment:)`.
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

    /// Resolve a connection from an environment dictionary.
    ///
    /// - Parameters:
    ///   - environment: the env to read (default: the process env).
    ///   - firstChoicePrefix: an optional consumer prefix (e.g. `"SHIKKI_DB_"`)
    ///     whose `<prefix>HOST/PORT/USER/NAME/PASSWORD` keys are tried BEFORE
    ///     libpq's `PGHOST/PGPORT/PGUSER/PGDATABASE/PGPASSWORD`.
    ///   - logger: where malformed-port warnings go; default label
    ///     `"backendkit.postgres.config"`. Injected for hermetic tests.
    public init(
        environment env: [String: String] = ProcessInfo.processInfo.environment,
        firstChoicePrefix: String? = nil,
        logger: Logger = Logger(label: "backendkit.postgres.config")
    ) {
        host = Self.resolveString(
            env: env,
            prefix: firstChoicePrefix,
            prefixSuffix: "HOST",
            libpqKey: "PGHOST"
        ) ?? Self.defaultHost

        port = Self.resolvePort(
            env: env,
            prefix: firstChoicePrefix,
            logger: logger
        )

        user = Self.resolveString(
            env: env,
            prefix: firstChoicePrefix,
            prefixSuffix: "USER",
            libpqKey: "PGUSER"
        ) ?? Self.defaultUser

        let resolvedDatabase = Self.resolveString(
            env: env,
            prefix: firstChoicePrefix,
            prefixSuffix: "NAME",
            libpqKey: "PGDATABASE"
        )
        // libpq's convention: PGDATABASE unset → same as user.
        database = resolvedDatabase ?? user

        password = Self.resolveString(
            env: env,
            prefix: firstChoicePrefix,
            prefixSuffix: "PASSWORD",
            libpqKey: "PGPASSWORD"
        )
    }

    // MARK: - Private helpers

    private static func resolveString(
        env: [String: String],
        prefix: String?,
        prefixSuffix: String,
        libpqKey: String
    ) -> String? {
        if let prefix, let value = env["\(prefix)\(prefixSuffix)"], !value.isEmpty {
            return value
        }
        if let value = env[libpqKey], !value.isEmpty {
            return value
        }
        return nil
    }

    private static func resolvePort(
        env: [String: String],
        prefix: String?,
        logger: Logger
    ) -> Int {
        if let prefix {
            let key = "\(prefix)PORT"
            if let raw = env[key], !raw.isEmpty {
                if let parsed = Int(raw) {
                    return parsed
                }
                logger.warning("malformed port in \(key)=\(raw) — falling through to libpq PGPORT / default \(defaultPort)")
            }
        }
        if let raw = env["PGPORT"], !raw.isEmpty {
            if let parsed = Int(raw) {
                return parsed
            }
            logger.warning("malformed port in PGPORT=\(raw) — falling back to default \(defaultPort)")
        }
        return defaultPort
    }
}
