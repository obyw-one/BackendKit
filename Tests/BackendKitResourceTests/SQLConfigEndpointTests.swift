import BackendKitSQL
import CoreKit
import CoreKitTestSupport
import Foundation
import SQLKit
import Testing

// MARK: - SQLConfigEndpointTests

//
// Spec d3f8a1b2 W5, BR-RP-13: the SQL backing of CoreKit's `ConfigEndpoint`. CoreKit's own conformance suite runs on
// every reachable engine; the tests after it are what only a table can get wrong.

@Suite("SQLConfigEndpoint — the AppConfig from a SQL table")
struct SQLConfigEndpointTests {

    static let seeded = AppConfigQuery(appId: "demo", environment: "prod")
    static let unknown = AppConfigQuery(appId: "ghost", environment: "prod")

    /// Seeds `query` with CoreKit's sample configuration through the same record a config server writes.
    static func seed(_ session: ResourceSession, _ query: AppConfigQuery, table: String? = nil) async throws -> AppConfig {
        let config = ConfigEndpointConformance.sampleConfig(for: query)
        let repository = SQLRepository<SQLConfigKey, SQLConfigRecord>(
            database: session.database, table: table ?? session.configTable,
            keyColumns: [SQLConfigSchema.Column.appId.rawValue, SQLConfigSchema.Column.environment.rawValue])
        try await repository.save(SQLConfigKey(query), data: SQLConfigRecord(config: config, environment: query.environment))
        return config
    }

    static func endpoint(_ session: ResourceSession) -> SQLConfigEndpoint {
        SQLConfigEndpoint(database: session.database, table: session.configTable)
    }

    @Test(
        "CoreKit's ConfigEndpoint conformance suite holds",
        arguments: ResourceEngine.available, ConfigEndpointConformance.Check.allCases)
    func conformance(engine: ResourceEngine, check: ConfigEndpointConformance.Check) async throws {
        let violations = try await engine.open().use { session in
            let expected = try await Self.seed(session, Self.seeded)
            let harness = ConfigEndpointHarness(
                label: "SQL / \(engine)", endpoint: Self.endpoint(session), query: Self.seeded, expected: expected,
                unknownQuery: Self.unknown)
            return await ConfigEndpointConformance.run(check, on: harness)
        }
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("one app in two environments is two rows, each answered on its own", arguments: ResourceEngine.available)
    func environmentsAreSeparate(engine: ResourceEngine) async throws {
        try await engine.open().use { session in
            let prod = try await Self.seed(session, AppConfigQuery(appId: "demo", environment: "prod"))
            let staging = try await Self.seed(session, AppConfigQuery(appId: "demo", environment: "staging"))
            let endpoint = Self.endpoint(session)
            #expect(try await endpoint.fetchConfig(AppConfigQuery(appId: "demo", environment: "prod")) == prod)
            #expect(try await endpoint.fetchConfig(AppConfigQuery(appId: "demo", environment: "staging")) == staging)
            #expect(prod != staging)
            await #expect(throws: ConfigEndpointError.notFound(AppConfigQuery(appId: "demo", environment: "dev"))) {
                _ = try await endpoint.fetchConfig(AppConfigQuery(appId: "demo", environment: "dev"))
            }
        }
    }

    @Test("a hostile app id is a bound value: it finds nothing and drops nothing", arguments: ResourceEngine.available)
    func hostileQueryIsData(engine: ResourceEngine) async throws {
        try await engine.open().use { session in
            _ = try await Self.seed(session, Self.seeded)
            let hostile = AppConfigQuery(appId: "x' OR '1'='1'; DROP TABLE \(session.configTable); --", environment: "prod")
            await #expect(throws: ConfigEndpointError.notFound(hostile)) { _ = try await Self.endpoint(session).fetchConfig(hostile) }
            #expect(try await Self.endpoint(session).fetchConfig(Self.seeded).appId == "demo", "the table did not survive")

            let stored = try await Self.seed(session, hostile)
            #expect(try await Self.endpoint(session).fetchConfig(hostile) == stored, "a hostile id is still a valid key")
        }
    }

    @Test("absent optionals stay absent: no message, no free-form data", arguments: ResourceEngine.available)
    func nilFieldsRoundTrip(engine: ResourceEngine) async throws {
        try await engine.open().use { session in
            let bare = AppConfig(
                id: "rec-1", appId: "demo", minVersion: "1.0.0", latestVersion: "1.0.0", killSwitch: true, maintenanceMode: false,
                maintenanceMessage: nil, featureFlags: RemoteFeatureFlags(), configData: nil)
            let repository = SQLRepository<SQLConfigKey, SQLConfigRecord>(
                database: session.database, table: session.configTable,
                keyColumns: [SQLConfigSchema.Column.appId.rawValue, SQLConfigSchema.Column.environment.rawValue])
            try await repository.save(SQLConfigKey(Self.seeded), data: SQLConfigRecord(config: bare, environment: "prod"))
            let fetched = try await Self.endpoint(session).fetchConfig(Self.seeded)
            #expect(fetched == bare)
            #expect(fetched.configData == nil && fetched.maintenanceMessage == nil)
            #expect(fetched.block == .killSwitch(message: nil))
        }
    }

    @Test("a missing table is the engine's error, never 'not found'", arguments: ResourceEngine.available)
    func engineFailureSurfaces(engine: ResourceEngine) async throws {
        try await engine.open().use { session in
            let endpoint = SQLConfigEndpoint(database: session.database, table: "no_such_table_\(UUID().uuidString.prefix(8).lowercased())")
            do {
                let config = try await endpoint.fetchConfig(Self.seeded)
                Issue.record("answered \(config) from a table that does not exist")
            } catch let error as ConfigEndpointError {
                Issue.record("an engine failure was reported as \(error)")
            } catch {
                #expect(!"\(error)".isEmpty)
            }
        }
    }

    @Test("a row the schema forbids is refused by the engine (kill_switch must be 0 or 1)", arguments: ResourceEngine.available)
    func booleanColumnsAreChecked(engine: ResourceEngine) async throws {
        try await engine.open().use { session in
            typealias Column = SQLConfigSchema.Column
            await #expect(throws: (any Error).self) {
                try await session.database.insert(into: session.configTable)
                    .columns(Column.allCases.map(\.rawValue))
                    .values(
                        SQLBind("rec"), SQLBind("demo"), SQLBind("prod"), SQLBind("1"), SQLBind("1"), SQLBind(Int64(2)), SQLBind(Int64(0)),
                        SQLLiteral.null, SQLBind("{}"), SQLLiteral.null)
                    .run()
            }
        }
    }

    @Test("malformed JSON in a column is reported with the column and the cause", arguments: ResourceEngine.available)
    func malformedJSONIsNamed(engine: ResourceEngine) async throws {
        try await engine.open().use { session in
            typealias Column = SQLConfigSchema.Column
            try await session.database.insert(into: session.configTable)
                .columns(Column.allCases.map(\.rawValue))
                .values(
                    SQLBind("rec"), SQLBind("demo"), SQLBind("prod"), SQLBind("1"), SQLBind("1"), SQLBind(Int64(0)), SQLBind(Int64(0)),
                    SQLLiteral.null, SQLBind("{not json"), SQLLiteral.null)
                .run()
            do {
                let config = try await Self.endpoint(session).fetchConfig(Self.seeded)
                Issue.record("decoded \(config) from malformed flags")
            } catch let error as SQLConfigEndpointError {
                guard case .malformedColumn(let column, let underlying) = error else { return }
                #expect(column == .featureFlags)
                #expect(!underlying.isEmpty, "the decoding cause was dropped")
            } catch {
                Issue.record("wrong error: \(error)")
            }
        }
    }
}
