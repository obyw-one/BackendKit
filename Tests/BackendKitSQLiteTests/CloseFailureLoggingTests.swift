import BackendKitTestSupport
import Foundation
import Testing
@testable import BackendKitSQLite

// MARK: - CloseFailureLoggingTests

//
// A connection close that cannot throw to its caller (a failed open, a deinit) must still leave a
// trace: the error goes through the host's logger. SQLiteNIO's `close()` only throws when its
// thread pool is shut down, which a test cannot cause on a live connection, so the failing close
// is injected into the same function the host's two close paths call.

private struct CloseRefused: Error, CustomStringConvertible {
    var description: String { "close-refused-sentinel" }
}

@Suite("SQLiteSQLHost — a failed connection close is logged with its error, never dropped")
struct CloseFailureLoggingTests {
    @Test("a throwing close is logged at error level with the error and the context")
    func failedCloseIsLogged() async {
        let capture = LogCapture()
        await SQLiteSQLHost.logFailure(
            of: { throw CloseRefused() },
            logger: capture.logger(),
            context: "while testing"
        )
        let entry = capture.entries.first
        #expect(capture.entries.count == 1)
        #expect(entry?.level == .error)
        #expect(entry?.message.contains("while testing") == true)
        #expect(entry?.metadata["error"].map { "\($0)" }?.contains("close-refused-sentinel") == true)
    }

    @Test("a close that succeeds logs nothing")
    func successfulCloseIsQuiet() async {
        let capture = LogCapture()
        await SQLiteSQLHost.logFailure(of: {}, logger: capture.logger(), context: "unused")
        #expect(capture.entries.isEmpty)
    }
}
