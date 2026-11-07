#if BACKENDKIT_POSTGRES
import BackendKitCore
import CoreKit
import Foundation
import Logging
import PostgresNIO

// MARK: - PostgresClientHost

//
// The ONE owner of a `PostgresClient`'s lifecycle in BackendKit (spec b7e2d4f6,
// BR-BKT-03) — extracted verbatim in shape from shikki's `PostgresClientHost`.
// A store holds one host and queries `host.client`. Connection comes from a
// `DBConnectionConfiguring` value injected at the call site; policy is the
// engine-agnostic `ConnectionPolicy` seam.
//
// Reconnect: capped exponential backoff (2^n s, max 60 s), first three
// attempts logged at warning, then every tenth. Every sleep goes through
// `CoreKit.TaskDeadline.sleep` — never a clock-based `Task.sleep`. The
// clock-based shape aborts the Swift 6 runtime under cancellation in a
// task group (backlog `d607d323`, CoreKit 0.9.0's release note).

public final class PostgresClientHost: @unchecked Sendable {
    public let client: PostgresClient
    private let runTask: Task<Void, Never>
    private let logger: Logger

    /// - Parameters:
    ///   - connection: the resolved connection (one value, injected once).
    ///   - policy: pool-timer knobs — defaults to `.shikki` (keep-alive off,
    ///     one-hour idle) to inherit the fleet's crash-avoidance settings.
    ///   - logger: the owning caller's logger; reconnect warnings carry its
    ///     label. Defaults to `"backendkit.postgres.host"`.
    ///   - reconnect: keep `run()` alive across broker outages (default).
    ///     `false` = one `run()`; the caller owns retries.
    public init(
        connection: any DBConnectionConfiguring,
        policy: ConnectionPolicy = .shikki,
        logger: Logger = Logger(label: "backendkit.postgres.host"),
        reconnect: Bool = true
    ) {
        let configuration = PostgresClient.Configuration.make(
            connection: connection,
            policy: policy
        )
        let client = PostgresClient(configuration: configuration)
        self.client = client
        self.logger = logger
        let log = logger
        runTask = Task {
            await ReconnectLoop.run(reconnect: reconnect, logger: log) { await client.run() }
        }
    }

    /// Cancel the long-running `run()` task. Idempotent.
    public func close() {
        runTask.cancel()
    }

    deinit {
        runTask.cancel()
    }
}

// MARK: - ReconnectLoop

/// The reconnect policy of `PostgresClientHost`, apart from the client so the backoff and the
/// cancellation handling are testable without a server: `serve` is `PostgresClient.run()`, `sleep`
/// is `TaskDeadline.sleep`.
enum ReconnectLoop {
    static func run(
        reconnect: Bool,
        logger: Logger,
        serve: @Sendable () async -> Void,
        sleep: @Sendable (Duration) async throws -> Void = { try await TaskDeadline.sleep($0) }
    ) async {
        var attempt = 0
        while !Task.isCancelled {
            await serve()
            if Task.isCancelled || !reconnect { return }
            attempt += 1
            let backoffSeconds = min(60, 1 << min(attempt, 6))
            if attempt <= 3 {
                logger.warning(
                    "pgClient.run() returned — reconnecting in \(backoffSeconds)s (attempt \(attempt))"
                )
            } else if attempt % 10 == 0 {
                logger.warning("pgClient still down after \(attempt) retries — backoff \(backoffSeconds)s")
            }
            do {
                try await sleep(.seconds(backoffSeconds))
            } catch is CancellationError {
                // `TaskDeadline.sleep` throws only `CancellationError`: the host was closed during the
                // backoff. That is the loop's stop signal, so leave deliberately instead of re-entering `serve()`.
                logger.debug("pgClient reconnect loop cancelled during backoff — stopping")
                return
            } catch {
                // Not a documented outcome of the sleep. Looping again would retry with no backoff at all,
                // so stop the loop and say why rather than hiding it.
                logger.error("pgClient reconnect backoff sleep failed — reconnect loop stopped", metadata: ["error": "\(error)"])
                return
            }
        }
    }
}
#endif
