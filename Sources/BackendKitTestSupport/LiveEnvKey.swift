import CoreKit

// MARK: - LiveEnvKey

/// The one switch the live-database tests read (a declared key, never a raw `environment["…"]`):
/// set `BACKENDKIT_LIVE_TESTS=1` to run the tests that need a real server.
public enum LiveEnvKey: String, EnvironmentKey {
    case liveTests = "BACKENDKIT_LIVE_TESTS"
}
