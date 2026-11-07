import CoreKitTestSupport
import Foundation
import PostgresNIO
import Testing
@testable import BackendKitCore
@testable import BackendKitPostgres

// MARK: - HostTests

//
// T-02 (spec b7e2d4f6, phase 4): `Configuration.make` carries the fixture
// verbatim and no environment key is read. The reconnect path (T-03) is
// enforced by CoreKit's `TaskDeadlineRatchet` over `Sources/BackendKitPostgres` —
// the host must use `TaskDeadline.sleep`, never the clock-based sleep. The whole
// package is held by `FleetRatchetsTests` in BackendKitCoreTests.

@Suite("PostgresClientHost — Configuration.make carries the fixture verbatim")
struct HostTests {
    // MARK: - Fixture

    struct Fixture: DBConnectionConfiguring, Sendable {
        let host: String
        let port: Int
        let user: String
        let database: String
        let password: String?
    }

    // MARK: - T-02

    @Test("Configuration.make carries the connection verbatim")
    func configurationMakeCarriesFixtureVerbatim() {
        let connection = Fixture(
            host: "explicit.host",
            port: 6543,
            user: "explicit-user",
            database: "explicit-db",
            password: "explicit-pw"
        )
        let policy = ConnectionPolicy(keepAlive: nil, idle: .seconds(3600))
        let config = PostgresClient.Configuration.make(
            connection: connection,
            policy: policy
        )

        #expect(config.host == "explicit.host")
        #expect(config.port == 6543)
        #expect(config.username == "explicit-user")
        #expect(config.password == "explicit-pw")
        #expect(config.database == "explicit-db")
        #expect(config.options.keepAliveBehavior == nil)
        #expect(config.options.connectionIdleTimeout == .seconds(3600))
    }

    @Test("policy keep-alive frequency threads through to Options.keepAliveBehavior")
    func policyKeepAliveIsUsed() {
        let connection = Fixture(host: "h", port: 1, user: "u", database: "d", password: nil)
        let policy = ConnectionPolicy(keepAlive: .seconds(45), idle: .seconds(120))
        let config = PostgresClient.Configuration.make(connection: connection, policy: policy)
        #expect(config.options.keepAliveBehavior?.frequency == .seconds(45))
        #expect(config.options.connectionIdleTimeout == .seconds(120))
    }

    @Test("default policy is `.shikki` (keep-alive off, one-hour idle)")
    func defaultPolicyIsShikki() {
        let connection = Fixture(host: "h", port: 1, user: "u", database: "d", password: nil)
        let config = PostgresClient.Configuration.make(connection: connection)
        #expect(config.options.keepAliveBehavior == nil)
        #expect(config.options.connectionIdleTimeout == .seconds(3600))
    }

    // MARK: - T-03: no clock-based sleep in the host

    @Test("PostgresClientHost sleeps through TaskDeadline, never the clock-based sleep")
    func hostUsesTaskDeadlineSleep() {
        let root = TestPackagePaths.sourcesRoot(ofModule: "BackendKitPostgres")
        #expect(FileManager.default.fileExists(atPath: root.path), "Sources/BackendKitPostgres not found at \(root.path)")
        // CoreKit's shared ratchet (BR-CKT-02) — the same scanner every kit stands on, not a local copy.
        let banned = TaskDeadlineRatchet.clockBasedSleeps(in: root)
        #expect(banned.isEmpty, "clock-based sleep in BackendKitPostgres: \(banned)")
    }
}
