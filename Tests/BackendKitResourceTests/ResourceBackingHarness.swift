import CoreKit
import CoreKitTestSupport
import Foundation
import SQLKit
@testable import BackendKitSQL

// MARK: - ResourceBackingHarness

/// Wires a ``SQLCacheBacking`` into CoreKit's two conformance suites.
enum ResourceBackingHarness {

    static let bucket: BucketName = "evidence"
    static let node: NodeID = "mac-a"

    static func backing(_ session: ResourceSession, node: NodeID = node) -> SQLCacheBacking {
        SQLCacheBacking(database: session.database, table: session.cacheTable, bucket: bucket, node: node)
    }

    /// Makes an entry older by rewriting its `modified` column, behind the backing's back: the one thing the suite
    /// cannot do through the protocol.
    static func age(_ session: ResourceSession, node: NodeID = node) -> @Sendable (String, TimeInterval) async throws -> Void {
        let backing = backing(session, node: node)
        let database = session.database
        let table = session.cacheTable
        return { entry, seconds in
            guard let current = try await backing.fetch(entry)?.modified else { return }
            let older = SQLCacheBacking.milliseconds(of: current.addingTimeInterval(-seconds))
            typealias Column = SQLCacheBackingSchema.Column
            try await database.update(table)
                .set(Column.modified.rawValue, to: older)
                .where(Column.bucket.rawValue, .equal, bucket.rawValue)
                .where(Column.node.rawValue, .equal, node.description)
                .where(Column.entry.rawValue, .equal, entry)
                .run()
        }
    }

    static func backingHarness(_ session: ResourceSession) -> CacheBackingHarness {
        CacheBackingHarness(label: "SQL / \(session.engine)", backing: backing(session), age: age(session))
    }

    static func repositoryHarness(_ session: ResourceSession) -> CacheConformanceHarness {
        let backing = backing(session)
        return CacheConformanceHarness(
            label: "SQL / \(session.engine) / AsyncCacheRepository",
            makePayloadSubject: { subject($0, over: backing) },
            makeTextSubject: { subject($0, over: backing) },
            storedBytes: { try await backing.fetch($0)?.data },
            plant: { try await backing.put($1, as: $0) },
            age: age(session))
    }

    private static func subject<Model: Codable & Sendable>(
        _ config: CacheConformanceConfig, over backing: some CacheBacking
    ) -> ConformanceSubject<Model> {
        let repository = AsyncCacheRepository<Model>(
            config.name, invalidateTime: config.invalidateTime, envelope: config.envelope,
            naming: config.naming, codec: config.codec, backing: backing)
        return ConformanceSubject(
            get: { try await repository.get($0) }, list: { try await repository.list() },
            save: { try await repository.save($0, data: $1) }, delete: { try await repository.delete($0) },
            exists: { try await repository.exists($0) })
    }
}
