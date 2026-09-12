import BackendKitCore
import CoreKit
import Foundation
import Logging
import PostgresNIO

// MARK: - PostgresRepositoryError

public enum PostgresRepositoryError: Error, Sendable, CustomStringConvertible {
  case notFound(idDescription: String)
  case invalidPayload(String)

  public var description: String {
    switch self {
    case .notFound(let id):
      "PostgresRepositoryError.notFound(id: \(id))"
    case .invalidPayload(let message):
      "PostgresRepositoryError.invalidPayload(\(message))"
    }
  }
}

// MARK: - PostgresRepository
//
// A CoreKit `RepositoryProtocol` conformer over one table (spec b7e2d4f6,
// BR-BKT-04). The table is `id + model` where `model` is JSONB — the same
// shape shikki uses for plans, decisions and context snapshots. A consumer
// imports BackendKit, registers a `PostgresRepository<UUID, MyModel>` in
// CoreKit's `Container`, and codes against `RepositoryProtocol` at the call
// site — never touching postgres-nio directly and never importing NetKit for
// persistence.
//
// Migration is the consumer's job: this type does not attempt to CREATE TABLE
// on init. A migration runner (BackendKit's own once W3 lands, or a consumer's
// existing one) sets up the schema up front — one SSoT for the table shape.

public actor PostgresRepository<ID, Model>: RepositoryProtocol
where
  ID: PostgresNonThrowingEncodable & PostgresDecodable & Hashable & Sendable,
  Model: Codable & Sendable
{

  // MARK: - Dependencies

  private let client: PostgresClient
  private let table: String
  private let idColumn: String
  private let modelColumn: String
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private let logger: Logger

  // MARK: - Init

  /// - Parameters:
  ///   - client: the `PostgresClient` from a `PostgresClientHost`.
  ///   - table: the SQL table this repository owns. The caller quotes the
  ///     identifier (`"my_records"` in Postgres is different from
  ///     `my_records`); pass an unquoted identifier for the default case.
  ///   - idColumn: the primary-key column. Default: `"id"`.
  ///   - modelColumn: the JSONB column holding the encoded model. Default:
  ///     `"model"`.
  ///   - encoder / decoder: the JSON codec pair. Defaults use ISO-8601 for
  ///     dates and preserve keys as declared — a consumer that needs
  ///     different date semantics passes its own encoder/decoder.
  ///   - logger: where decode errors go. Default label:
  ///     `"backendkit.postgres.repository"`.
  public init(
    client: PostgresClient,
    table: String,
    idColumn: String = "id",
    modelColumn: String = "model",
    encoder: JSONEncoder? = nil,
    decoder: JSONDecoder? = nil,
    logger: Logger = Logger(label: "backendkit.postgres.repository")
  ) {
    self.client = client
    self.table = table
    self.idColumn = idColumn
    self.modelColumn = modelColumn
    self.encoder = encoder ?? PostgresRepository.defaultEncoder()
    self.decoder = decoder ?? PostgresRepository.defaultDecoder()
    self.logger = logger
  }

  // MARK: - RepositoryProtocol

  public func get(_ id: ID) async throws -> Model {
    let sql = "SELECT \(modelColumn)::text FROM \(table) WHERE \(idColumn) = $1 LIMIT 1"
    var binds = PostgresBindings(capacity: 1)
    binds.append(id, context: .default)
    let query = PostgresQuery(unsafeSQL: sql, binds: binds)

    let rows = try await client.query(query, logger: logger)
    for try await row in rows {
      let (json) = try row.decode(String.self)
      return try decode(json: json)
    }
    throw PostgresRepositoryError.notFound(idDescription: String(describing: id))
  }

  public func list() async throws -> [Model] {
    let sql = "SELECT \(modelColumn)::text FROM \(table)"
    let query = PostgresQuery(unsafeSQL: sql, binds: PostgresBindings())

    let rows = try await client.query(query, logger: logger)
    var out: [Model] = []
    for try await row in rows {
      let (json) = try row.decode(String.self)
      out.append(try decode(json: json))
    }
    return out
  }

  public func save(_ id: ID, data: Model) async throws {
    let json = try encodeToString(data)
    let sql = """
      INSERT INTO \(table) (\(idColumn), \(modelColumn)) VALUES ($1, $2::jsonb)
      ON CONFLICT (\(idColumn)) DO UPDATE SET \(modelColumn) = EXCLUDED.\(modelColumn)
      """
    var binds = PostgresBindings(capacity: 2)
    binds.append(id, context: .default)
    binds.append(json, context: .default)
    let query = PostgresQuery(unsafeSQL: sql, binds: binds)
    _ = try await client.query(query, logger: logger)
  }

  public func delete(_ id: ID) async throws {
    let sql = "DELETE FROM \(table) WHERE \(idColumn) = $1 RETURNING \(idColumn)"
    var binds = PostgresBindings(capacity: 1)
    binds.append(id, context: .default)
    let query = PostgresQuery(unsafeSQL: sql, binds: binds)
    let rows = try await client.query(query, logger: logger)
    var deleted = false
    for try await _ in rows { deleted = true }
    if !deleted {
      throw PostgresRepositoryError.notFound(idDescription: String(describing: id))
    }
  }

  // MARK: - JSON codec defaults

  public static func defaultEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  public static func defaultDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  // MARK: - Private helpers

  private func encodeToString(_ model: Model) throws -> String {
    let data = try encoder.encode(model)
    guard let json = String(data: data, encoding: .utf8) else {
      throw PostgresRepositoryError.invalidPayload("JSON bytes are not valid UTF-8")
    }
    return json
  }

  private func decode(json: String) throws -> Model {
    guard let data = json.data(using: .utf8) else {
      throw PostgresRepositoryError.invalidPayload("row JSON is not valid UTF-8")
    }
    return try decoder.decode(Model.self, from: data)
  }
}
