import BackendKitSQL
import BackendKitSQLite
import BackendKitTestSupport
import CoreKit
import Foundation
import Testing

// MARK: - NotesRepositoryAssembly

//
// T-07 (spec b4f8c3a1): "if the engine is swapped behind `Container`, the same `SQLRepository`
// API works". The consumer registers ONE protocol (`any RepositoryProtocol<UUID, Note>`) and the
// environment picks the implementation: the real SQL engine in production, CoreKit's own
// `InMemoryRepository` in mock — prod and test differ only by the injected `DIEnvironment`
// (`di-container-one-impl`), never by a parallel code path.

private struct NotesRepositoryAssembly: DIAssembly {
    let sqlite: SQLiteSQLHost

    func assemble(container: Container, environment: DIEnvironment) {
        switch environment {
        case .production:
            container.register((any RepositoryProtocol<UUID, Note>).self) { [sqlite] _ in
                SQLRepository<UUID, Note>(database: sqlite.database, table: "notes")
            }
        case .mock:
            container.register((any RepositoryProtocol<UUID, Note>).self) { _ in
                InMemoryRepository<UUID, Note>()
            }
        }
    }
}

// MARK: - NotesConsumer

/// A consumer the way the fleet writes one: it names the protocol, never the engine, and gets it
/// from the container through `@Resolve`.
private struct NotesConsumer {
    @Resolve var repository: any RepositoryProtocol<UUID, Note>

    /// save -> get -> overwrite -> list -> delete -> get-after-delete, through the protocol only.
    mutating func roundTrip() async throws {
        let repository = repository
        let note = Note(id: UUID(), title: "first", count: 1)
        try await repository.save(note.id, data: note)
        #expect(try await repository.get(note.id) == note)

        let renamed = Note(id: note.id, title: "renamed", count: 2)
        try await repository.save(note.id, data: renamed)
        #expect(try await repository.list() == [renamed])

        try await repository.delete(note.id)
        var missing = false
        do { _ = try await repository.get(note.id) } catch { missing = true }
        #expect(missing, "get after delete must throw, whichever engine is behind the container")
    }
}

// MARK: - RepositoryContainerSwapTests

@Suite("SQLRepository behind CoreKit's Container — the engine swaps with the environment (T-07)", .serialized)
struct RepositoryContainerSwapTests {
    @Test("the same consumer code round-trips on every environment", arguments: [DIEnvironment.production, .mock])
    func sameConsumerOnEveryEnvironment(environment: DIEnvironment) async throws {
        let host = try await SQLiteSQLHost.open(storage: .memory)
        defer { DI.reset() }
        do {
            try await host.database.raw("CREATE TABLE notes (id TEXT PRIMARY KEY, title TEXT NOT NULL, count INTEGER NOT NULL)").run()
            DI.configure(for: environment, assemblies: [NotesRepositoryAssembly(sqlite: host)])

            var consumer = NotesConsumer()
            try await consumer.roundTrip()
        } catch {
            try? await host.shutdown()
            throw error
        }
        try await host.shutdown()
    }

    @Test("the environment really selects the implementation: SQL in production, in-memory in mock")
    func environmentSelectsTheImplementation() async throws {
        let host = try await SQLiteSQLHost.open(storage: .memory)
        defer { DI.reset() }

        DI.configure(for: .production, assemblies: [NotesRepositoryAssembly(sqlite: host)])
        let production = DI.require((any RepositoryProtocol<UUID, Note>).self)
        #expect(production is SQLRepository<UUID, Note>)

        DI.configure(for: .mock, assemblies: [NotesRepositoryAssembly(sqlite: host)])
        let mock = DI.require((any RepositoryProtocol<UUID, Note>).self)
        #expect(mock is InMemoryRepository<UUID, Note>)

        try await host.shutdown()
    }
}
