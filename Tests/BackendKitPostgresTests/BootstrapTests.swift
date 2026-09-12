import Testing
@testable import BackendKitPostgres

@Suite("BackendKitPostgres bootstrap") struct BootstrapTests { @Test func packageBuilds() { #expect(true) } }
