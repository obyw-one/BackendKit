import Foundation

// MARK: - ConnectionInjectionRatchet
//
// The scan helper every consumer runs to hold the "one value, injected once"
// rule (spec b7e2d4f6, BR-BKT-05). It reproduces the two rules of shikki's
// `DBConnectionConfigInjectionRatchetTests`:
//
//   1. NO `<Config>().<field>` outside the resolver — a fresh
//      `PostgresConnectionConfig().host` call rebuilds the config for every
//      field access, which is the exact shape PR #1669 fixed (six identical
//      instances per store).
//   2. Raw `PG*` and prefixed connection-key reads outside the resolver only
//      go DOWN — a consumer feeds a baseline of legacy call sites and the
//      test fails when a new one appears.
//
// The helper returns two lists of `file:line` locations; a consumer wires
// them into its own tests. It does not read the process env itself.

public enum ConnectionInjectionRatchet {

  // MARK: - ScanResult

  public struct ScanResult: Sendable, Equatable {
    /// `Sources/Foo/Bar.swift:42` — a line matching `<Config>().<field>`.
    public let fieldAccess: [String]

    /// `Sources/Foo/Bar.swift:42` — a line reading a connection env key
    /// (`PGHOST`, `PGPORT`, …, or `<prefix>HOST/PORT/USER/NAME/PASSWORD`
    /// when a prefix was supplied).
    public let rawEnvReads: [String]

    public init(fieldAccess: [String], rawEnvReads: [String]) {
      self.fieldAccess = fieldAccess
      self.rawEnvReads = rawEnvReads
    }
  }

  // MARK: - Errors

  public struct RatchetError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
  }

  // MARK: - Scan

  /// Walk every `.swift` file under `sourcesRoot`, skipping the resolver's
  /// own file and any file in `ownerFiles`, and report every line that
  /// either accesses a field on a fresh resolver value or reads a raw
  /// connection env key.
  ///
  /// - Parameters:
  ///   - sourcesRoot: the tree to scan — a consumer typically passes its
  ///     `Sources/` directory.
  ///   - configTypeNames: the resolver types whose `.<field>` uses are
  ///     banned. Defaults to `["PostgresConnectionConfig"]`; a consumer
  ///     that wraps the kit (shikki's `ShikkiDBConnection`) passes both.
  ///   - firstChoicePrefixes: the consumer prefixes to also treat as raw
  ///     env reads. Defaults to `[]` — kit-only scans watch only `PG*`.
  ///   - ownerFiles: relative paths (from `sourcesRoot`, `Sources/`-
  ///     prefixed) whose contents are exempt — the resolver itself lives
  ///     here. Defaults to no exemptions beyond files named exactly like
  ///     the config types (e.g. `PostgresConnectionConfig.swift`).
  public static func scan(
    sourcesRoot: URL,
    configTypeNames: [String] = ["PostgresConnectionConfig"],
    firstChoicePrefixes: [String] = [],
    ownerFiles: Set<String> = []
  ) throws -> ScanResult {
    guard let enumerator = FileManager.default.enumerator(atPath: sourcesRoot.path) else {
      throw RatchetError("no Sources dir at \(sourcesRoot.path)")
    }

    let fieldAccessPattern = try Self.makeFieldAccessRegex(configTypeNames: configTypeNames)
    let envKeyPattern = try Self.makeEnvKeyRegex(prefixes: firstChoicePrefixes)
    let exemptFilenames = Set(configTypeNames.map { "\($0).swift" })

    var fieldAccess: [String] = []
    var rawEnvReads: [String] = []

    for case let rel as String in enumerator where rel.hasSuffix(".swift") {
      let filename = (rel as NSString).lastPathComponent
      if exemptFilenames.contains(filename) { continue }

      let posixRel = "Sources/\(rel)"
      if ownerFiles.contains(posixRel) { continue }

      let url = sourcesRoot.appendingPathComponent(rel)
      let content = try String(contentsOf: url, encoding: .utf8)
      for (index, line) in content.components(separatedBy: "\n").enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }

        let range = NSRange(line.startIndex..., in: line)
        if fieldAccessPattern.firstMatch(in: line, range: range) != nil {
          fieldAccess.append("\(posixRel):\(index + 1)")
        }
        if envKeyPattern.firstMatch(in: line, range: range) != nil {
          rawEnvReads.append("\(posixRel):\(index + 1)")
        }
      }
    }

    return ScanResult(fieldAccess: fieldAccess, rawEnvReads: rawEnvReads)
  }

  // MARK: - Regex builders

  private static func makeFieldAccessRegex(configTypeNames: [String]) throws -> NSRegularExpression
  {
    let alternation = configTypeNames.map(NSRegularExpression.escapedPattern(for:)).joined(
      separator: "|")
    return try NSRegularExpression(pattern: #"(\#(alternation))\(\)\."#)
  }

  private static func makeEnvKeyRegex(prefixes: [String]) throws -> NSRegularExpression {
    var alternatives: [String] = [#"PG(HOST|PORT|USER|PASSWORD|DATABASE)"#]
    for prefix in prefixes {
      let escaped = NSRegularExpression.escapedPattern(for: prefix)
      alternatives.append(#"\#(escaped)(HOST|PORT|USER|NAME|PASSWORD)"#)
    }
    let alternation = alternatives.joined(separator: "|")
    return try NSRegularExpression(pattern: #"\["(\#(alternation))"\]"#)
  }
}
