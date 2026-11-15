import Logging
import NIOConcurrencyHelpers

// MARK: - LogCapture

/// An in-memory `Logger` sink, so a test can assert that a failure was LOGGED with its error
/// rather than dropped.
///
/// swift-log's `LogHandler.log(event:)` is synchronous, so an actor cannot sit behind it; the entries live in a
/// `NIOLockedValueBox`, which is `Sendable` without an `@unchecked`, and so is this class.
public final class LogCapture: Sendable {
    public struct Entry: Sendable {
        public let level: Logger.Level
        public let message: String
        public let metadata: Logger.Metadata
    }

    private let stored = NIOLockedValueBox<[Entry]>([])

    public init() {}

    public var entries: [Entry] {
        stored.withLockedValue { $0 }
    }

    public func logger() -> Logger {
        Logger(label: "backendkit.test.capture") { _ in CapturingLogHandler(capture: self) }
    }

    fileprivate func append(_ entry: Entry) {
        stored.withLockedValue { $0.append(entry) }
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
