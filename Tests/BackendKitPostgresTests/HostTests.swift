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
// enforced by a source scan on `Sources/BackendKitPostgres` — the host must
// use `TaskDeadline.sleep`, never `Task.sleep(for:)`.

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

    @Test("PostgresClientHost sleeps through TaskDeadline, never Task.sleep(for:)")
    func hostUsesTaskDeadlineSleep() throws {
        let root = Self.postgresSourcesRoot()
        guard FileManager.default.fileExists(atPath: root.path) else {
            Issue.record("Sources/BackendKitPostgres not found at \(root.path)")
            return
        }
        let banned = try findBannedSleepShape(in: root)
        #expect(banned.isEmpty, "clock-based sleep in BackendKitPostgres: \(banned)")
    }

    // MARK: - Helpers

    /// CoreKit's `TestPackagePaths` is the fleet SSoT for "where is my
    /// package" (BackendKit #2 review) — no hand-counted `#filePath` walk.
    private static func postgresSourcesRoot() -> URL {
        TestPackagePaths.sourcesRoot(ofModule: "BackendKitPostgres")
    }

    private func findBannedSleepShape(in root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            return []
        }
        // Ban `Task.sleep(for:` — the clock-based shape that aborts the
        // Swift 6 runtime under cancellation (CoreKit 0.9.0 release note).
        let pattern = try NSRegularExpression(pattern: #"Task\.sleep\(for:"#)
        var hits: [String] = []
        for case let rel as String in enumerator where rel.hasSuffix(".swift") {
            let url = root.appendingPathComponent(rel)
            let content = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in content.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                if pattern.firstMatch(in: line, range: range) != nil {
                    hits.append("Sources/BackendKitPostgres/\(rel):\(index + 1)")
                }
            }
        }
        return hits
    }
}
