import Foundation

// MARK: - DBConnectionConfiguring
//
// The engine-agnostic connection seam of the fleet (spec b7e2d4f6, BR-BKT-02).
// A store or client host takes ONE `connection: any DBConnectionConfiguring`
// value — resolved once at the call site — never five scalars each defaulting
// to a fresh resolver, and never rebuilds a config in its body. Production
// injects `PostgresConnectionConfig(environment:firstChoicePrefix:)` (or a
// consumer-shaped wrapper like shikki's `ShikkiDBConnection`); tests inject an
// explicit fixture. Deployment concerns (docker container names, socket paths)
// stay in the consumer — the seam is engine-agnostic on purpose.

public protocol DBConnectionConfiguring: Sendable {
    var host: String { get }
    var port: Int { get }
    var user: String { get }
    var database: String { get }
    var password: String? { get }
}

// MARK: - psql invocation shape
//
// BR-BKT-02b: the `psql` invocation shape is the seam's too. Every consumer
// that shells out to `psql` needs the same `-h/-p/-U/-d --no-psqlrc` argument
// vector, with the password left to `PGPASSWORD` (never on the command line).
// A single extension keeps that shape in one place — shikki's
// `CompanyMergeEngine`, `SemanticRecallActor` and `DBShellExecuting.psql`
// become call sites of this helper.

extension DBConnectionConfiguring {
    /// The `-h/-p/-U/-d --no-psqlrc` argument vector every `psql` invocation
    /// needs. `--no-psqlrc` is deliberate: an operator's `~/.psqlrc` (e.g.
    /// `\timing`, `\pset border`) contaminates captured output when a caller
    /// parses `psql -tAc` results. The password is intentionally NOT in the
    /// vector — pass it via the `PGPASSWORD` environment variable so it never
    /// appears in a process listing.
    public var psqlConnectionArguments: [String] {
        [
            "-h", host,
            "-p", String(port),
            "-U", user,
            "-d", database,
            "--no-psqlrc",
        ]
    }
}
