#if BACKENDKIT_POSTGRES
import Foundation
import Logging
import Testing
@testable import BackendKitPostgres

// MARK: - ReconnectLoopTests

//
// The reconnect policy of `PostgresClientHost`, run without a server: `serve` stands for
// `PostgresClient.run()` returning (a broker outage), `sleep` for `TaskDeadline.sleep`.
// What matters here is what happens to a CANCELLED backoff: it stops the loop on purpose, and
// anything else the sleep throws is logged as an error instead of being swallowed.

private actor Recorder {
    private(set) var serves = 0
    private(set) var sleeps: [Duration] = []
    func served() { serves += 1 }
    func slept(_ duration: Duration) { sleeps.append(duration) }
}

private struct UnexpectedSleepFailure: Error, CustomStringConvertible {
    var description: String { "unexpected-sleep-sentinel" }
}

@Suite("PostgresClientHost reconnect loop — backoff and cancellation")
struct ReconnectLoopTests {
    @Test("a cancelled backoff stops the loop after exactly one run, with a debug trace and no error")
    func cancelledBackoffStopsTheLoop() async {
        let recorder = Recorder()
        let capture = LogCapture()
        await ReconnectLoop.run(
            reconnect: true,
            logger: capture.logger(),
            serve: { await recorder.served() },
            sleep: { duration in
                await recorder.slept(duration)
                throw CancellationError()
            }
        )
        #expect(await recorder.serves == 1)
        #expect(await recorder.sleeps == [.seconds(2)])
        #expect(capture.entries.contains { $0.level == .debug && $0.message.contains("cancelled during backoff") })
        #expect(capture.entries.filter { $0.level >= .error }.isEmpty)
    }

    @Test("a sleep that fails for any other reason stops the loop and is logged as an error with the cause")
    func unexpectedSleepFailureIsLoggedNotHidden() async {
        let recorder = Recorder()
        let capture = LogCapture()
        await ReconnectLoop.run(
            reconnect: true,
            logger: capture.logger(),
            serve: { await recorder.served() },
            sleep: { _ in throw UnexpectedSleepFailure() }
        )
        #expect(await recorder.serves == 1)
        let errors = capture.entries.filter { $0.level == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.metadata["error"].map { "\($0)" }?.contains("unexpected-sleep-sentinel") == true)
    }

    @Test("the backoff doubles per attempt and is capped at 60 seconds")
    func backoffLadder() async {
        let recorder = Recorder()
        let sleepCount = Counter()
        await ReconnectLoop.run(
            reconnect: true,
            logger: LogCapture().logger(),
            serve: { await recorder.served() },
            sleep: { duration in
                await recorder.slept(duration)
                if await sleepCount.increment() == 8 { throw CancellationError() }
            }
        )
        #expect(await recorder.sleeps == [2, 4, 8, 16, 32, 60, 60, 60].map { Duration.seconds($0) })
    }

    @Test("reconnect: false runs the client once and never sleeps")
    func noReconnectRunsOnce() async {
        let recorder = Recorder()
        await ReconnectLoop.run(
            reconnect: false,
            logger: LogCapture().logger(),
            serve: { await recorder.served() },
            sleep: { duration in await recorder.slept(duration) }
        )
        #expect(await recorder.serves == 1)
        #expect(await recorder.sleeps.isEmpty)
    }
}

private actor Counter {
    private var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}
#endif
