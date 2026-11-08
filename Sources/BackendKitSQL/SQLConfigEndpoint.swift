import CoreKit
import Foundation
import SQLKit

// MARK: - SQLConfigSchema

/// The table a ``SQLConfigEndpoint`` reads: one row per `(app_id, env)`.
///
/// It holds the same record PocketBase serves and ``AppConfig`` decodes: the snake_case
/// fields of `AppConfig`, plus `env` (named as in NetKit's `PocketConfigEndpoint`, so a
/// config server can move between the two). The two booleans are `0`/`1` integers
/// with a `CHECK`, because a SQLite `STRICT` table has no boolean type and one
/// definition has to serve every engine; the flags and the free-form data are JSON text.
public enum SQLConfigSchema {

    public enum Column: String, CaseIterable, Sendable {
        case id
        case appId = "app_id"
        case environment = "env"
        case minVersion = "min_version"
        case latestVersion = "latest_version"
        case killSwitch = "kill_switch"
        case maintenanceMode = "maintenance_mode"
        case maintenanceMessage = "maintenance_message"
        case featureFlags = "feature_flags"
        case configData = "config_data"
    }

    /// The table definition; pass it to `SQLiteSQLHost.createStrictTable(_:_:)` or ``create(on:table:)``.
    public static func configure(_ builder: SQLCreateTableBuilder) -> SQLCreateTableBuilder {
        builder
            .column(Column.id.rawValue, type: .text, .notNull, .unique)
            .column(Column.appId.rawValue, type: .text, .notNull)
            .column(Column.environment.rawValue, type: .text, .notNull)
            .column(Column.minVersion.rawValue, type: .text, .notNull)
            .column(Column.latestVersion.rawValue, type: .text, .notNull)
            .column(Column.killSwitch.rawValue, type: .int, .notNull)
            .column(Column.maintenanceMode.rawValue, type: .int, .notNull)
            .column(Column.maintenanceMessage.rawValue, type: .text)
            .column(Column.featureFlags.rawValue, type: .text, .notNull)
            .column(Column.configData.rawValue, type: .text)
            .primaryKey(Column.appId.rawValue, Column.environment.rawValue)
            .check(isBoolean(.killSwitch), named: constraintName(.killSwitch))
            .check(isBoolean(.maintenanceMode), named: constraintName(.maintenanceMode))
    }

    /// `column IN (0, 1)`, built from the typed expression tree.
    private static func isBoolean(_ column: Column) -> any SQLExpression {
        SQLBinaryExpression(
            left: SQLIdentifier(column.rawValue), op: SQLBinaryOperator.in,
            right: SQLGroupExpression(SQLList([SQLLiteral.numeric("0"), SQLLiteral.numeric("1")])))
    }

    private static func constraintName(_ column: Column) -> String { "\(column.rawValue)_is_boolean" }

    /// `CREATE TABLE IF NOT EXISTS` for Postgres and DuckDB.
    public static func create(on database: any SQLDatabase, table: String) async throws {
        try await configure(database.create(table: table).ifNotExists()).run()
    }
}

// MARK: - SQLConfigEndpointError

/// A row the table holds but ``AppConfig`` cannot be made from.
public enum SQLConfigEndpointError: Error, Sendable, CustomStringConvertible, LocalizedError {
    /// A column holds something outside the schema's contract (not 0 or 1, not JSON of the expected shape).
    case malformedColumn(SQLConfigSchema.Column, underlying: String)

    public var description: String {
        switch self {
        case .malformedColumn(let column, let underlying):
            "SQLConfigEndpoint: column '\(column.rawValue)' is malformed — \(underlying)"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - SQLConfigKey

/// The primary key of a configuration row; its coding keys are the key columns.
public struct SQLConfigKey: Codable, Hashable, Sendable {
    public let appId: String
    public let environment: String

    public init(_ query: AppConfigQuery) {
        appId = query.appId
        environment = query.environment
    }

    private enum CodingKeys: String, CodingKey {
        case appId = "app_id"
        case environment = "env"
    }
}

// MARK: - SQLConfigRecord

/// One row of the configuration table, as the columns hold it.
public struct SQLConfigRecord: Codable, Sendable, Equatable {
    public let id: String
    public let appId: String
    public let environment: String
    public let minVersion: String
    public let latestVersion: String
    public let killSwitch: Int64
    public let maintenanceMode: Int64
    public let maintenanceMessage: String?
    public let featureFlags: String
    public let configData: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case appId = "app_id"
        case environment = "env"
        case minVersion = "min_version"
        case latestVersion = "latest_version"
        case killSwitch = "kill_switch"
        case maintenanceMode = "maintenance_mode"
        case maintenanceMessage = "maintenance_message"
        case featureFlags = "feature_flags"
        case configData = "config_data"
    }

    /// The row that holds `config` for `environment`: how a config server (or a test) seeds the table.
    public init(config: AppConfig, environment: String) throws {
        id = config.id
        appId = config.appId
        self.environment = environment
        minVersion = config.minVersion
        latestVersion = config.latestVersion
        killSwitch = config.killSwitch ? 1 : 0
        maintenanceMode = config.maintenanceMode ? 1 : 0
        maintenanceMessage = config.maintenanceMessage
        featureFlags = try Self.json(config.featureFlags, column: .featureFlags)
        configData = try config.configData.map { try Self.json($0, column: .configData) }
    }

    /// The ``AppConfig`` this row holds.
    /// - Throws: ``SQLConfigEndpointError/malformedColumn(_:underlying:)`` for a column outside the contract.
    public func appConfig() throws -> AppConfig {
        AppConfig(
            id: id, appId: appId, minVersion: minVersion, latestVersion: latestVersion,
            killSwitch: try Self.boolean(killSwitch, column: .killSwitch),
            maintenanceMode: try Self.boolean(maintenanceMode, column: .maintenanceMode),
            maintenanceMessage: maintenanceMessage,
            featureFlags: try Self.decode(RemoteFeatureFlags.self, from: featureFlags, column: .featureFlags),
            configData: try configData.map { try Self.decode([String: String].self, from: $0, column: .configData) })
    }

    private static func json(_ value: some Encodable, column: SQLConfigSchema.Column) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw SQLConfigEndpointError.malformedColumn(column, underlying: "\(error)")
        }
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw SQLConfigEndpointError.malformedColumn(column, underlying: "the encoded JSON is not UTF-8")
        }
        return text
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type, from text: String, column: SQLConfigSchema.Column
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: Data(text.utf8))
        } catch {
            throw SQLConfigEndpointError.malformedColumn(column, underlying: "\(error)")
        }
    }

    private static func boolean(_ value: Int64, column: SQLConfigSchema.Column) throws -> Bool {
        switch value {
        case 0: false
        case 1: true
        default: throw SQLConfigEndpointError.malformedColumn(column, underlying: "\(value) is neither 0 nor 1")
        }
    }
}

// MARK: - SQLConfigEndpoint

/// CoreKit's ``ConfigEndpoint`` over a SQL table (spec d3f8a1b2, BR-RP-13, W5): a server or a CLI
/// that reads its configuration straight from SQLite, DuckDB or Postgres, through the same
/// ``AppConfigService`` that reads PocketBase through NetKit's `PocketConfigEndpoint`.
///
/// Reads through ``SQLRepository`` (`get` by the `(app_id, env)` key, every value bound). Matches
/// the PocketBase endpoint on both outcomes: no row is ``ConfigEndpointError/notFound(_:)``, and
/// anything else the engine raises (a connection, a missing table, a malformed row) is thrown
/// unchanged, never turned into a default.
public struct SQLConfigEndpoint: ConfigEndpoint {

    private let repository: SQLRepository<SQLConfigKey, SQLConfigRecord>

    /// - Parameters:
    ///   - database: the injected engine (`host.database` of any BackendKit host).
    ///   - table: a table created from ``SQLConfigSchema``.
    public init(database: any SQLDatabase, table: String) {
        repository = SQLRepository(
            database: database, table: table,
            keyColumns: [SQLConfigSchema.Column.appId.rawValue, SQLConfigSchema.Column.environment.rawValue])
    }

    public func fetchConfig(_ query: AppConfigQuery) async throws -> AppConfig {
        let record: SQLConfigRecord
        do {
            record = try await repository.get(SQLConfigKey(query))
        } catch SQLRepositoryError.notFound {
            throw ConfigEndpointError.notFound(query)
        }
        return try record.appConfig()
    }
}
