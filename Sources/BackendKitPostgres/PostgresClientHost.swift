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
//
// Concurrency: the host holds only immutable, `Sendable` state (`PostgresClient` is `Sendable`, a `Task` is
// `Sendable`, so is `Logger`), so it is a plain checked-`Sendable` class — no lock, no actor. An actor would
// serialise nothing: the only mutation is the reconnect loop's attempt counter, a local of the ONE task that runs
// it. The loop is a method of `ReconnectPolicy` (data + the interpretation of that data), not of the host, on
// purpose: a loop that captured the host would keep it alive for as long as it runs, and `deinit` — which cancels
// the loop — could then never fire.

public final class PostgresClientHost: Sendable {
    public let client: PostgresClient
    private let runTask: Task<Void, Never>

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
        let reconnectPolicy = ReconnectPolicy(reconnect: reconnect)
        runTask = Task {
            await reconnectPolicy.run(logger: logger) { await client.run() }
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

// MARK: - ReconnectPolicy

/// The reconnect policy of `PostgresClientHost` — the backoff ladder as DATA, and the one loop that interprets it.
/// Apart from the client so the backoff and the cancellation handling are testable without a server: `serve` is
/// `PostgresClient.run()`, `sleep` is `TaskDeadline.sleep`.
struct ReconnectPolicy: Sendable, Equatable {
    /// `false` = serve once and return; the caller owns retries.
    let reconnect: Bool
    /// The wait before attempt `n` is `backoff[n - 1]`; attempts past the end of the ladder keep its last rung.
    let backoff: [Duration]
    /// The first `warnFirst` attempts are logged at warning …
    let warnFirst: Int
    /// … then every `warnEvery`-th one.
    let warnEvery: Int

    /// Capped exponential backoff: 2, 4, 8, 16, 32, then 60 seconds for ever.
    static let standardBackoff: [Duration] = [2, 4, 8, 16, 32, 60].map { Duration.seconds($0) }

    init(
        reconnect: Bool,
        backoff: [Duration] = ReconnectPolicy.standardBackoff,
        warnFirst: Int = 3,
        warnEvery: Int = 10
    ) {
        precondition(!backoff.isEmpty, "a reconnect backoff ladder needs at least one rung")
        self.reconnect = reconnect
        self.backoff = backoff
        self.warnFirst = warnFirst
        self.warnEvery = warnEvery
    }

    /// How long to wait after the `attempt`-th return of `serve` (1-based).
    func delay(afterAttempt attempt: Int) -> Duration {
        backoff[min(attempt, backoff.count) - 1]
    }

    func run(
        logger: Logger,
        serve: @Sendable () async -> Void,
        sleep: @Sendable (Duration) async throws -> Void = { try await TaskDeadline.sleep($0) }
    ) async {
        var attempt = 0
        while !Task.isCancelled {
            await serve()
            if Task.isCancelled || !reconnect { return }
            attempt += 1
            let delay = delay(afterAttempt: attempt)
            let backoffSeconds = delay.components.seconds
            if attempt <= warnFirst {
                logger.warning(
                    "pgClient.run() returned — reconnecting in \(backoffSeconds)s (attempt \(attempt))"
                )
            } else if attempt % warnEvery == 0 {
                logger.warning("pgClient still down after \(attempt) retries — backoff \(backoffSeconds)s")
            }
            do {
                try await sleep(delay)
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
