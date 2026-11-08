import BackendKitSQL
import CoreKit
import CoreKitTestSupport
import Foundation
import Testing

// MARK: - SQLCacheBackingConformanceTests

//
// Spec d3f8a1b2 W4, T-11: CoreKit's two conformance suites, unchanged, over a database table. SQLite and DuckDB run
// everywhere; Postgres joins them when BACKENDKIT_LIVE_TESTS=1 points at a live server (libpq variables).

@Suite("SQLCacheBacking — CoreKit's cache conformance suites on every reachable engine (T-11)")
struct SQLCacheBackingConformanceTests {

    @Test(
        "the backing contract holds",
        arguments: ResourceEngine.available, CacheBackingConformance.Check.allCases)
    func backingContract(engine: ResourceEngine, check: CacheBackingConformance.Check) async throws {
        let violations = try await engine.open().use { session in
            await CacheBackingConformance.run(check, on: ResourceBackingHarness.backingHarness(session))
        }
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test(
        "the cache behaviour suite holds through AsyncCacheRepository",
        arguments: ResourceEngine.available, CacheRepositoryConformance.Check.allCases)
    func repositoryBehaviour(engine: ResourceEngine, check: CacheRepositoryConformance.Check) async throws {
        let violations = try await engine.open().use { session in
            await CacheRepositoryConformance.run(check, on: ResourceBackingHarness.repositoryHarness(session))
        }
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("both suites are complete: no check can be silently skipped")
    func suitesAreComplete() {
        #expect(CacheBackingConformance.implementedChecks == CacheBackingConformance.Check.allCases)
        #expect(CacheRepositoryConformance.implementedChecks == CacheRepositoryConformance.Check.allCases)
        #expect(CacheBackingConformance.Check.allCases.count == 10)
        #expect(CacheRepositoryConformance.Check.allCases.count == 17)
    }
}
