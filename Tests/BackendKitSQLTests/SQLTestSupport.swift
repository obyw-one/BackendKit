import BackendKitCore
import BackendKitPostgres
import CoreKit
import Foundation

// MARK: - LiveEnvKey

/// The one switch this target reads (declared key, never a raw `environment["…"]`).
enum LiveEnvKey: String, EnvironmentKey {
    case liveTests = "BACKENDKIT_LIVE_TESTS"
}

// MARK: - LiveDatabase

enum LiveDatabase {
    static let environment = TypedEnvironment.current()

    static var isLive: Bool {
        environment.flag(LiveEnvKey.liveTests)
    }

    static func connection() -> PostgresConnectionConfig {
        PostgresConnectionConfig(environment: environment)
    }
}
