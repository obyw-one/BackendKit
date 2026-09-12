import Foundation

// MARK: - ConnectionPolicy

//
// The engine-agnostic pool-timer knobs (spec b7e2d4f6, BR-BKT-02). shikki's
// pool-timer mitigation (crash `shi-dev-2026-09-11-142913.ips` in
// `ConnectionPool.runTimer`) removed keep-alive queries and stretched the
// idle timeout to one hour. The kit exposes those two knobs so every
// consumer picks them explicitly rather than inheriting postgres-nio's
// defaults by accident — a `keepAlive: nil` value disables the keep-alive
// query entirely.

public struct ConnectionPolicy: Sendable, Hashable {
    /// The frequency at which an idle connection runs a keep-alive query,
    /// or `nil` to disable the keep-alive query altogether. postgres-nio's
    /// default is `.seconds(30)`; shikki's crash-avoidance value is `nil`.
    public let keepAlive: Duration?

    /// How long an idle connection is kept in the pool before being closed.
    /// postgres-nio's default is `.seconds(60)`; shikki's crash-avoidance
    /// value is `.seconds(3600)` (one hour).
    public let idle: Duration

    public init(keepAlive: Duration?, idle: Duration) {
        self.keepAlive = keepAlive
        self.idle = idle
    }

    /// The policy shikki's pool-timer mitigation settled on — keep-alive
    /// disabled, idle timeout stretched to one hour. Every fleet consumer
    /// that has no reason to pick something else starts here.
    public static let shikki = ConnectionPolicy(keepAlive: nil, idle: .seconds(3600))

    /// postgres-nio's out-of-the-box defaults — for tests that want to
    /// assert we chose something different from the dependency's own values.
    public static let postgresNIODefaults = ConnectionPolicy(
        keepAlive: .seconds(30),
        idle: .seconds(60)
    )
}
