import Testing
@testable import BackendKitCore

@Suite("BackendKitCore bootstrap") struct BootstrapTests { @Test func packageBuilds() { #expect(true) } }
