import CoreKitTestSupport
import Foundation
import Testing
@testable import BackendKitCore

// MARK: - RawProcessEnvRatchetTests

//
// BackendKit #2 review (RepositoryLiveTests, PostgresConnectionConfig): the
// process environment is read in ONE place in the fleet —
// `CoreKit.TypedEnvironment.current()` — and every other reader takes a
// `TypedEnvironment` and declared `EnvironmentKey`s. This ratchet holds the
// kit's own `Sources/` and `Tests/` at zero raw reads (the ratchet helper's
// fixture strings are the one sanctioned mention, exempted by name).

@Suite("No raw process-env read in BackendKit — TypedEnvironment is the SSoT")
struct RawProcessEnvRatchetTests {
    @Test("Sources/ has zero raw process-env reads")
    func sourcesAreClean() throws {
        let result = try ConnectionInjectionRatchet.scan(sourcesRoot: TestPackagePaths.sourcesRoot())
        #expect(result.processEnvReads.isEmpty, "raw process-env reads in Sources/: \(result.processEnvReads)")
        #expect(result.rawEnvReads.isEmpty, "raw connection-key reads in Sources/: \(result.rawEnvReads)")
        #expect(result.fieldAccess.isEmpty, "fresh-resolver field access in Sources/: \(result.fieldAccess)")
    }

    @Test("Tests/ has zero raw process-env reads outside the ratchet's own fixtures")
    func noRawReadsUnderTests() throws {
        let testsRoot = TestPackagePaths.packageRoot().appendingPathComponent("Tests", isDirectory: true)
        let result = try ConnectionInjectionRatchet.scan(
            sourcesRoot: testsRoot,
            ownerFiles: ["Sources/BackendKitCoreTests/RatchetHelperTests.swift"]
        )
        #expect(result.processEnvReads.isEmpty, "raw process-env reads in Tests/: \(result.processEnvReads)")
    }
}
