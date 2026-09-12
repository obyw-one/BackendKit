import CoreKitTestSupport
import Foundation
import Testing

// MARK: - NoRuntimeSpecCopyInTreeTests

//
// Same rule as shikki's `NoRuntimeSpecCopyInTreeTests` (review #1670) and
// CoreKit's `.gitignore` (review #21): the wave engine drops the dispatched
// spec at the repository root as `.shikki-spec.md` for headless agents. It is
// runtime scratch. The flow deletes it before the final commit and the PR —
// LOUDLY. It must never be silenced through `.gitignore` (that hides the
// process defect instead of surfacing it — BackendKit #2 review, `.gitignore`
// line 6) and it must never be in the delivered tree. Engine-side fix:
// shikki backlog e5cb00ab.

@Suite("No `.shikki-spec.md` in the delivered tree — loud, never ignored")
struct NoRuntimeSpecCopyInTreeTests {
    @Test("the package root carries no `.shikki-spec.md`")
    func noRuntimeSpecCopyAtPackageRoot() {
        let copy = TestPackagePaths.packageRoot().appendingPathComponent(".shikki-spec.md")
        #expect(
            !FileManager.default.fileExists(atPath: copy.path),
            "`.shikki-spec.md` is the wave engine's runtime copy of the spec — the flow must delete it before the final commit (shikki backlog e5cb00ab); found at \(copy.path)"
        )
    }

    @Test("`.gitignore` never silences `.shikki-spec.md` — the process defect must stay visible")
    func gitignoreDoesNotHideTheRuntimeSpecCopy() throws {
        let ignore = TestPackagePaths.packageRoot().appendingPathComponent(".gitignore")
        guard FileManager.default.fileExists(atPath: ignore.path) else { return }
        let lines = try String(contentsOf: ignore, encoding: .utf8)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let hidden = lines.filter { !$0.hasPrefix("#") && $0.contains(".shikki-spec.md") }
        #expect(
            hidden.isEmpty,
            "\(ignore.path) ignores `.shikki-spec.md` — remove it; the engine must delete the file, not hide it: \(hidden)"
        )
    }
}
