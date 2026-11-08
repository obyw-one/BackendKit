import BackendKitCore
import CoreKit

// MARK: - LiveDatabase

/// The live-database gate and connection of the tests, built from an injected `TypedEnvironment` (default: the one
/// process snapshot) so a test can hand it a fixed environment. `BACKENDKIT_LIVE_TESTS=1` turns the live tests on.
public struct LiveDatabase: Sendable {
    private let environment: TypedEnvironment
    private let firstChoicePrefix: String?

    public init(environment: TypedEnvironment = .current(), firstChoicePrefix: String? = nil) {
        self.environment = environment
        self.firstChoicePrefix = firstChoicePrefix
    }

    public var isLive: Bool {
        environment.flag(LiveEnvKey.liveTests)
    }

    public func connection() -> PostgresConnectionConfig {
        PostgresConnectionConfig(environment: environment, firstChoicePrefix: firstChoicePrefix)
    }
}
