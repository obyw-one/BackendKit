import BackendKitTestSupport
import CoreKit
import Foundation
import Logging
import Testing
@testable import BackendKitPostgres

// MARK: - ReconnectPolicyTests

//
// `ReconnectPolicy` (the reconnect policy of `PostgresClientHost`), run without a server and without real time:
// `serve` stands for `PostgresClient.run()` returning (a broker outage) and every wait goes through CoreKit's
// `FakeDrainClock`, which advances virtual time by exactly the slept amount and records each request. A wrong
// ladder, a counter that never resets or a real sleep sneaking in shows up as data (or as a slow test).

private struct UnexpectedSleepFailure: Error, CustomStringConvertible {
    var description: String { "unexpected-sleep-sentinel" }
}

/// A clock whose sleep always fails with `error`, to drive the loop's two exit paths.
private struct FailingClock: DrainClock {
    let error: any Error
    func now() -> Date { Date(timeIntervalSince1970: 0) }
    func sleep(for seconds: TimeInterval) async throws { throw error }
}

private actor Serves {
    private(set) var count = 0
    func served() { count += 1 }
}

private func seconds(_ values: [Int]) -> [TimeInterval] { values.map { TimeInterval($0) } }

@Suite("ReconnectPolicy — backoff ladder on a fake clock")
struct ReconnectPolicyTests {
    @Test("the waits are exactly 2, 4, 8, 16, 32, 60, 60, 60 seconds, in virtual time")
    func ladderSequence() async {
        let clock = FakeDrainClock(cancelAfterSleeps: 8)
        let started = ContinuousClock.now
        await ReconnectPolicy(reconnect: true).run(logger: LogCapture().logger(), serve: {}, clock: clock)
        #expect(clock.sleeps == seconds([2, 4, 8, 16, 32, 60, 60, 60]))
        // 242 virtual seconds elapsed; the real elapsed time proves nothing slept for real.
        #expect(clock.now().timeIntervalSince1970 == 242)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("a serve that stayed up for the stability window restarts the ladder at 2 seconds")
    func counterResetsAfterAStableConnection() async {
        let clock = FakeDrainClock(cancelAfterSleeps: 8)
        let serveCount = Serves()
        // Even serves are short outages (virtual time does not move), odd ones are 120 s of healthy connection,
        // which the clock records as a 120 s sleep of its own.
        await ReconnectPolicy(reconnect: true).run(
            logger: LogCapture().logger(),
            serve: {
                await serveCount.served()
                if await serveCount.count % 3 == 0 { try? await clock.sleep(for: 120) }
            },
            clock: clock
        )
        // serves 1, 2 fail fast (waits 2, 4); serve 3 is stable (+120 s) so the ladder restarts: 2, 4, 8; serve 6 again.
        #expect(clock.sleeps == seconds([2, 4, 120, 2, 4, 8, 120, 2]))
    }

    @Test("a serve shorter than the stability window does not reset the ladder")
    func shortServeKeepsClimbing() async {
        let clock = FakeDrainClock(cancelAfterSleeps: 4)
        await ReconnectPolicy(reconnect: true).run(
            logger: LogCapture().logger(),
            serve: { try? await clock.sleep(for: 59) },
            clock: clock
        )
        // every serve lasts 59 s (< 60 s): the waits climb, interleaved with the serves' own 59 s sleeps.
        #expect(clock.sleeps == seconds([59, 2, 59, 4]))
    }

    @Test("a cancelled backoff stops the loop after exactly one run, with a debug trace and no error")
    func cancelledBackoffStopsTheLoop() async {
        let capture = LogCapture()
        let serveCount = Serves()
        await ReconnectPolicy(reconnect: true).run(
            logger: capture.logger(),
            serve: { await serveCount.served() },
            clock: FailingClock(error: CancellationError())
        )
        #expect(await serveCount.count == 1)
        #expect(capture.entries.contains { $0.level == .debug && $0.message.contains("cancelled during backoff") })
        #expect(capture.entries.filter { $0.level >= .error }.isEmpty)
    }

    @Test("cancelling the task during a backoff wakes the wait and ends the loop without another serve")
    func taskCancellationMidWait() async {
        let serveCount = Serves()
        let policy = ReconnectPolicy(reconnect: true)
        let entered = Serves()
        let task = Task {
            await policy.run(
                logger: LogCapture().logger(),
                serve: { await serveCount.served() },
                clock: ParkedClock(onSleep: { await entered.served() })
            )
        }
        while await entered.isEmpty { await Task.yield() }
        task.cancel()
        await task.value
        #expect(await serveCount.count == 1)
    }

    @Test("a sleep that fails for any other reason stops the loop and is logged as an error with the cause")
    func unexpectedSleepFailureIsLoggedNotHidden() async {
        let capture = LogCapture()
        let serveCount = Serves()
        await ReconnectPolicy(reconnect: true).run(
            logger: capture.logger(),
            serve: { await serveCount.served() },
            clock: FailingClock(error: UnexpectedSleepFailure())
        )
        #expect(await serveCount.count == 1)
        let errors = capture.entries.filter { $0.level == .error }
        #expect(errors.count == 1)
        #expect(errors.first?.metadata["error"].map { "\($0)" }?.contains("unexpected-sleep-sentinel") == true)
    }

    @Test("reconnect: false runs the client once and never waits")
    func noReconnectRunsOnce() async {
        let clock = FakeDrainClock()
        let serveCount = Serves()
        await ReconnectPolicy(reconnect: false).run(
            logger: LogCapture().logger(),
            serve: { await serveCount.served() },
            clock: clock
        )
        #expect(await serveCount.count == 1)
        #expect(clock.sleeps.isEmpty)
    }
}

/// A clock that waits until the surrounding task is cancelled, then throws `CancellationError`: a backoff that is
/// still in progress when the host closes.
private struct ParkedClock: DrainClock {
    let onSleep: @Sendable () async -> Void
    func now() -> Date { Date(timeIntervalSince1970: 0) }
    func sleep(for seconds: TimeInterval) async throws {
        await onSleep()
        while !Task.isCancelled { await Task.yield() }
        throw CancellationError()
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
        let clock = FakeDrainClock(cancelAfterSleeps: 4)
        let policy = ReconnectPolicy(reconnect: true, backoff: [.seconds(1), .seconds(3)])
        await policy.run(logger: LogCapture().logger(), serve: {}, clock: clock)
        #expect(clock.sleeps == seconds([1, 3, 3, 3]))
    }
}
