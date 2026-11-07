import CoreKitTestSupport
import Foundation
import Testing

@testable import BackendKitDuckDB

// MARK: - DuckDBVersionPinTests

//
// The two sides of BackendKitDuckDB run different DuckDB versions (duckdb-swift has no stable DuckDB 2.x release and
// does not build on Linux). `DuckDBVersionPins` is the one place that records both. These tests make a version bump
// deliberate on BOTH sides: the library that actually loaded must be the pinned one, and every other file that
// names a version must agree with the pins.

@Suite("DuckDB version pins — the library that loads is the one that is recorded")
struct DuckDBVersionPinTests {
    private static func packageFile(_ path: String) throws -> String {
        try String(contentsOf: TestPackagePaths.packageRoot().appendingPathComponent(path), encoding: .utf8)
    }

    @Test("the DuckDB library loaded on this platform reports exactly the pinned version")
    func runtimeVersionIsThePinnedOne() async throws {
        let reported = try await withDuckDBEngine { try await $0.libraryVersion() }
        #expect(reported == DuckDBEngine.pinnedLibraryVersion, "this platform loaded DuckDB \(reported); bump DuckDBVersionPins deliberately, on both sides")
        #if os(Linux)
        #expect(reported == DuckDBVersionPins.linuxLibraryVersion)
        #else
        #expect(reported == DuckDBVersionPins.appleLibraryVersion)
        #endif
    }

    @Test("Package.swift pins the duckdb-swift tag that DuckDBVersionPins names")
    func manifestMatchesThePins() throws {
        let manifest = try Self.packageFile("Package.swift")
        #expect(
            manifest.contains(#".package(url: "https://github.com/duckdb/duckdb-swift.git", exact: "\#(DuckDBVersionPins.appleSwiftBindingTag)")"#),
            "Package.swift must pin duckdb-swift exactly at \(DuckDBVersionPins.appleSwiftBindingTag)"
        )
        #expect(DuckDBVersionPins.appleLibraryVersion == "v\(DuckDBVersionPins.appleSwiftBindingTag)", "a dev tag reports itself as v<tag>")
    }

    @Test("Scripts/libduckdb.lock pins the libduckdb release that DuckDBVersionPins names, with a full sha256 per architecture")
    func lockFileMatchesThePins() throws {
        let lock = try Self.packageFile("Scripts/libduckdb.lock")
        let entries = Dictionary(
            uniqueKeysWithValues: lock.split(separator: "\n").filter { !$0.hasPrefix("#") && $0.contains("=") }.map { line -> (String, String) in
                let parts = line.split(separator: "=", maxSplits: 1)
                return (String(parts[0]), String(parts[1]))
            }
        )
        #expect(entries["LIBDUCKDB_VERSION"] == DuckDBVersionPins.linuxLibraryVersion)
        for key in ["LIBDUCKDB_SHA256_AMD64", "LIBDUCKDB_SHA256_ARM64"] {
            let digest = entries[key] ?? ""
            #expect(digest.count == 64 && digest.allSatisfy(\.isHexDigit) && digest == digest.lowercased(), "\(key) must be a lowercase 64-digit sha256")
        }
        #expect(entries["LIBDUCKDB_SHA256_AMD64"] != entries["LIBDUCKDB_SHA256_ARM64"])
    }

    @Test("the installer refuses an archive whose sha256 is not the pinned one, and installs nothing")
    func installerChecksTheDigest() throws {
        let script = try Self.packageFile("Scripts/install-libduckdb.sh")
        #expect(script.contains("set -eu"))
        #expect(script.contains("sha256 mismatch"))
        // The digest check comes before the archive is opened.
        let check = try #require(script.range(of: "sha256 mismatch"))
        let extract = try #require(script.range(of: "tar -xzf"))
        #expect(check.lowerBound < extract.lowerBound)
    }
}
