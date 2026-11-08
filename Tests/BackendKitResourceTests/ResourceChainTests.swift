import BackendKitSQL
import CoreKit
import CoreKitTestSupport
import Foundation
import SQLKit
import Testing

// MARK: - ResourceChainTests

//
// T-11 end to end: CoreKit's `AppConfigService` fetches from the SQL `ConfigEndpoint` and caches through the
// `AsyncCacheRepository` over the SQL `CacheBacking`, so one database serves as the config source AND the offline
// cache. Nothing in the consumer names an engine.

@Suite("AppConfigService over SQL — fetch once, cache in the same database, survive the source going away")
struct ResourceChainTests {

    @Test("bootstrap fetches from the SQL source and a later launch reads the SQL cache", arguments: ResourceEngine.available)
    func fetchThenCache(engine: ResourceEngine) async throws {
        try await engine.open().use { session in
            let query = SQLConfigEndpointTests.seeded
            let expected = try await SQLConfigEndpointTests.seed(session, query)
            let cache = AsyncCacheRepository<AppConfig>(
                "app-config", invalidateTime: .never, backing: ResourceBackingHarness.backing(session))

            let first = AppConfigService(query: query, endpoint: SQLConfigEndpointTests.endpoint(session), cache: cache)
            #expect(await first.bootstrap() == .fetched)
            #expect(await first.currentConfig == expected)

            // The source goes away; a new launch starts from the SQL cache alone.
            let gone = SQLConfigEndpoint(database: session.database, table: "no_such_table_\(UUID().uuidString.prefix(8).lowercased())")
            let second = AppConfigService(query: query, endpoint: gone, cache: cache)
            #expect(await second.bootstrap() == .usingCache)
            #expect(await second.currentConfig == expected)
        }
    }

    @Test("with no source and an empty cache the app runs on local defaults: nothing is invented", arguments: ResourceEngine.available)
    func nothingIsInvented(engine: ResourceEngine) async throws {
        try await engine.open().use { session in
            let cache = AsyncCacheRepository<AppConfig>(
                "app-config", invalidateTime: .never, backing: ResourceBackingHarness.backing(session))
            let service = AppConfigService(
                query: SQLConfigEndpointTests.seeded, endpoint: SQLConfigEndpointTests.endpoint(session), cache: cache)
            #expect(await service.bootstrap() == .unavailable)
            #expect(await service.currentConfig == nil)
        }
    }
}
