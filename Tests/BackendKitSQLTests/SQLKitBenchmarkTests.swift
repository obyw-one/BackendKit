import BackendKitPostgres
import BackendKitTestSupport
import SQLKitBenchmark
import XCTest

// SQLKit's own driver-conformance suite against the Postgres driver (spec b4f8c3a1 W1 gate).
// Needs a live database; gated by BACKENDKIT_LIVE_TESTS=1.
final class SQLKitBenchmarkTests: XCTestCase {
    func testPostgresDriverConformance() async throws {
        try XCTSkipUnless(LiveDatabase().isLive, "set BACKENDKIT_LIVE_TESTS=1 with a scratch database")
        let host = PostgresSQLHost(connection: LiveDatabase().connection())
        do {
            try await SQLBenchmarker(on: host.database).runAllTests()
        } catch {
            try? await host.shutdown()
            throw error
        }
        try await host.shutdown()
    }
}
