import BackendKitCore
import BackendKitPostgres
import BackendKitTestSupport
import CoreKit
import Foundation

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
