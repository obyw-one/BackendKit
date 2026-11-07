import BackendKitTestSupport
import Foundation
import Logging
import Testing
@testable import BackendKitPostgres

// MARK: - ReconnectPolicyTests

//
// `ReconnectPolicy` (the reconnect policy of `PostgresClientHost`), run without a server: `serve` stands for
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

@Suite("ReconnectPolicy — backoff and cancellation")
struct ReconnectPolicyTests {
    @Test("a cancelled backoff stops the loop after exactly one run, with a debug trace and no error")
    func cancelledBackoffStopsTheLoop() async {
        let recorder = Recorder()
        let capture = LogCapture()
        await ReconnectPolicy(reconnect: true).run(
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
        await ReconnectPolicy(reconnect: true).run(
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
        await ReconnectPolicy(reconnect: true).run(
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
        await ReconnectPolicy(reconnect: false).run(
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

@Suite("ReconnectPolicy — the ladder is data")
struct ReconnectPolicyDataTests {
    @Test("the standard ladder is 2, 4, 8, 16, 32, 60 seconds and stays at 60")
    func standardLadder() {
        let policy = ReconnectPolicy(reconnect: true)
        let delays = (1...9).map { policy.delay(afterAttempt: $0) }
        #expect(delays == [2, 4, 8, 16, 32, 60, 60, 60, 60].map { Duration.seconds($0) })
    }

    @Test("a custom ladder is honoured: the loop is the interpreter, the ladder is the data")
    func customLadder() async {
        let recorder = Recorder()
        let sleepCount = Counter()
        let policy = ReconnectPolicy(reconnect: true, backoff: [.seconds(1), .seconds(3)])
        await policy.run(
            logger: LogCapture().logger(),
            serve: { await recorder.served() },
            sleep: { duration in
                await recorder.slept(duration)
                if await sleepCount.increment() == 4 { throw CancellationError() }
            }
        )
        #expect(await recorder.sleeps == [1, 3, 3, 3].map { Duration.seconds($0) })
    }
}
