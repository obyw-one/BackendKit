#if BACKENDKIT_POSTGRES
import Foundation
import Logging

// MARK: - LogCapture

/// An in-memory `Logger` sink, so a test can assert that a failure was LOGGED with its error
/// rather than dropped. (BackendKitSQLiteTests has its own copy; a third would belong in a shared target.)
final class LogCapture: @unchecked Sendable {
    struct Entry: Sendable {
        let level: Logger.Level
        let message: String
        let metadata: Logger.Metadata
    }

    private let lock = NSLock()
    private var stored: [Entry] = []

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func logger() -> Logger {
        Logger(label: "backendkit.test.capture") { _ in CapturingLogHandler(capture: self) }
    }

    fileprivate func append(_ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(entry)
    }
}

// MARK: - CapturingLogHandler

struct CapturingLogHandler: LogHandler {
    let capture: LogCapture
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        capture.append(.init(level: event.level, message: "\(event.message)", metadata: event.metadata ?? [:]))
    }
}
#endif
