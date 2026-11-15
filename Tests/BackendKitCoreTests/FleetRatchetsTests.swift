import CoreKitTestSupport
import Foundation
import Testing

// MARK: - FleetRatchetsTests

//
// BackendKit consumes the two ratchets CoreKit 0.12 ships in `CoreKitTestSupport` instead of keeping
// its own scanner per rule:
//
//   * `TaskDeadlineRatchet` — no clock-based `Task.sleep(for:)` anywhere in `Sources/` or `Tests/`
//     (the shape that aborts the Swift 6 runtime when the sleeper is cancelled inside a task group;
//     CoreKit 0.9.0 release note). `PostgresClientHost` already sleeps through `TaskDeadline`; this
//     holds the WHOLE package there, tests included.
//   * `CountedDepthWalkRatchet` — no hand-counted path walk from the test file in `Tests/`: a test locates its
//     package through `TestPackagePaths` (spec one-path-resolution-ssot BR-PATH-02).
//
// Each ratchet is also driven against a fixture that SHOULD trip it, so a green run proves the
// scanner is wired and not just silent.

@Suite("Fleet ratchets — TaskDeadline and path resolution hold across Sources/ and Tests/")
struct FleetRatchetsTests {
    private static let scratch = TestScratch.forPackage()

    // MARK: - TaskDeadline

    @Test("Sources/ has no clock-based Task.sleep")
    func sourcesHaveNoClockBasedSleep() {
        let hits = TaskDeadlineRatchet.clockBasedSleeps(in: TestPackagePaths.sourcesRoot())
        #expect(hits.isEmpty, "clock-based sleep in Sources/ — use CoreKit.TaskDeadline.sleep: \(hits)")
    }

    @Test("Tests/ has no clock-based Task.sleep")
    func testsHaveNoClockBasedSleep() {
        let testsRoot = TestPackagePaths.packageRoot().appendingPathComponent("Tests", isDirectory: true)
        let hits = TaskDeadlineRatchet.clockBasedSleeps(in: testsRoot)
        #expect(hits.isEmpty, "clock-based sleep in Tests/ — use CoreKit.TaskDeadline.sleep: \(hits)")
    }

    @Test("the TaskDeadline ratchet reports a clock-based sleep in a fixture tree")
    func taskDeadlineRatchetIsWired() throws {
        let tree = try Self.scratch.makeScratchDir(scope: "fleet-ratchets")
        defer { try? Self.scratch.removeScratchDir(tree) }
        // Spelled in two pieces so this file does not trip the ratchet it exercises.
        let banned = "try await Task." + "sleep(for: .seconds(1))"
        try "func wait() async throws {\n    \(banned)\n}\n"
            .write(to: tree.appendingPathComponent("Waiter.swift"), atomically: true, encoding: .utf8)

        let hits = TaskDeadlineRatchet.clockBasedSleeps(in: tree)
        #expect(hits.count == 1)
        #expect(hits.first?.contains("Waiter.swift:2") == true)
    }

    // MARK: - Counted-depth path walk

    @Test("Tests/ has no counted-depth path walk")
    func testsHaveNoCountedDepthWalk() throws {
        let testsRoot = TestPackagePaths.packageRoot().appendingPathComponent("Tests", isDirectory: true)
        let hits = try CountedDepthWalkRatchet.scan(testsRoot: testsRoot)
        #expect(hits.isEmpty, "counted-depth path walk in Tests/ — use TestPackagePaths: \(hits)")
    }

    @Test("the counted-depth ratchet reports a hand-counted walk in fixture text")
    func countedDepthRatchetIsWired() {
        let source = "let root = URL(fileURLWithPath: " + "#file" + "Path).deletingLastPathComponent()\n"
        let hits = CountedDepthWalkRatchet.scanText(source, at: "Fixture.swift")
        #expect(hits == [CountedDepthWalkRatchet.Hit(file: "Fixture.swift", line: 1)])
    }
}
