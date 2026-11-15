import Foundation
import Testing
@testable import BackendKitCore

/// Spec c8fa126c W5 — f1a7c3e8's T-03, which asked that BackendKit pin the new
/// CoreKit tag and cross-build.
///
/// BackendKit is the one package in this wave that was ALREADY clean: zero
/// Apple-only imports, zero `#if`, both musl triples exit 0. What was wrong was
/// its manifest — it pinned `FJ-Studios/CoreKit` 0.9.1, the old org and eight
/// minors back, and its own header comment asserted "CoreKit is NOT Linux-clean
/// today". That claim stopped being true at CoreKit 0.14.0.
///
/// This ratchet exists because "already clean" is the state that regresses
/// silently: a backend runs on Linux, and the first `import os` added here would
/// be caught by nothing until a deploy
/// ([[a-wave-that-adds-a-ratchet-binds-every-later-wave]]).
@Suite("BackendKit portability ratchet")
struct BackendKitPortabilityRatchetTests {
    private static let forbidden = [
        "os", "SwiftUI", "Combine", "Network", "UIKit", "AppKit", "CryptoKit", "Security", "Metal",
        "CoreFoundation",
    ]

    private static func sourcesRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appending(path: "Package.swift").path) {
                return dir.appending(path: "Sources", directoryHint: .isDirectory)
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("no Package.swift above \(#filePath)")
    }

    @Test("no Apple-only import anywhere in BackendKit — it is Foundation, CoreKit and PostgresNIO")
    func noAppleImports() throws {
        var offenders: [String] = []
        let files = try Self.swiftFiles(under: Self.sourcesRoot())
        #expect(files.count > 5, "ratchet scanned too few files — locator drift?")
        for file in files {
            for (index, raw) in try Self.lines(of: file).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("import ") else { continue }
                let module = line.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
                if Self.forbidden.contains(module) {
                    offenders.append("\(file.lastPathComponent):\(index + 1) import \(module)")
                }
            }
        }
        #expect(offenders.isEmpty, "Apple-only imports in BackendKit: \(offenders)")
    }

    /// BackendKit has ZERO `#if` today and that is the state worth pinning: a
    /// server-side package has no platform to choose between. The first one to
    /// appear should be argued for in review, not discovered in a deploy.
    @Test("BackendKit carries no compilation condition at all")
    func noCompilationConditions() throws {
        var offenders: [String] = []
        for file in try Self.swiftFiles(under: Self.sourcesRoot()) {
            for (index, raw) in try Self.lines(of: file).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#if") {
                    offenders.append("\(file.lastPathComponent):\(index + 1) \(line)")
                }
            }
        }
        #expect(offenders.isEmpty, "compilation conditions in BackendKit: \(offenders)")
    }

    /// The manifest claim this wave corrected, pinned as text so it cannot drift
    /// back: the dependency is obyw-one's CoreKit, and the floor is the first
    /// release that cross-builds for Linux.
    @Test("the CoreKit dependency is obyw-one's, at the Linux-clean floor")
    func coreKitPinIsCurrent() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/", !FileManager.default.fileExists(atPath: dir.appending(path: "Package.swift").path) {
            dir = dir.deletingLastPathComponent()
        }
        let manifest = try String(contentsOf: dir.appending(path: "Package.swift"), encoding: .utf8)
        #expect(
            manifest.contains("obyw-one/CoreKit.git"),
            "FJ-Studios/CoreKit is the old org; a pin there resolves a CoreKit that is not Linux-clean"
        )
        // `FJ-Studios/CoreKit.git`, with the `.git`, is the PIN form. Matching
        // the bare `FJ-Studios/CoreKit` flagged this wave's own manifest
        // comment, which names the old pin as history — measured, the first run
        // of this test failed on my own prose
        // ([[strip-comments-before-quoting-a-sweep-size]]). A ratchet must
        // measure the thing it names, and the thing named here is a dependency
        // declaration, not a mention.
        #expect(!manifest.contains("FJ-Studios/CoreKit.git"))
        #expect(manifest.contains("from: \"0.17.0\""), "0.17.0 is the measured Linux-clean floor")
    }

    private static func lines(of file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
