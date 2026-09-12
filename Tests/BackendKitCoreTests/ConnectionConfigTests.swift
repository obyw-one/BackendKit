import Testing

@testable import BackendKitCore

// MARK: - ConnectionConfigTests
//
// T-01 (spec b7e2d4f6, phase 4): the prefix wins per key, libpq fills the
// rest. Explicit inits round-trip verbatim; the psql argument vector matches
// the seam's shape (`-h/-p/-U/-d --no-psqlrc`, password left to PGPASSWORD).

@Suite("PostgresConnectionConfig — libpq resolver, one value, injected once")
struct ConnectionConfigTests {

  // MARK: - T-01 shape

  @Test("prefix wins per key; libpq fills the rest")
  func prefixWinsPerKeyLibpqFillsTheRest() {
    let config = PostgresConnectionConfig(
      environment: [
        "PGHOST": "pg.example",
        "SHIKKI_DB_PORT": "6000",
      ],
      firstChoicePrefix: "SHIKKI_DB_"
    )
    #expect(config.host == "pg.example")
    #expect(config.port == 6000)
  }

  @Test("prefix HOST wins over PGHOST when both are set")
  func prefixHostWinsOverLibpq() {
    let config = PostgresConnectionConfig(
      environment: [
        "PGHOST": "libpq.host",
        "SHIKKI_DB_HOST": "prefixed.host",
      ],
      firstChoicePrefix: "SHIKKI_DB_"
    )
    #expect(config.host == "prefixed.host")
  }

  @Test("no prefix means libpq keys are the only choice")
  func noPrefixMeansLibpqOnly() {
    let config = PostgresConnectionConfig(
      environment: [
        "PGHOST": "pg.example",
        "PGPORT": "5433",
        "PGUSER": "alice",
        "PGDATABASE": "analytics",
        "PGPASSWORD": "s3cret",
      ]
    )
    #expect(config.host == "pg.example")
    #expect(config.port == 5433)
    #expect(config.user == "alice")
    #expect(config.database == "analytics")
    #expect(config.password == "s3cret")
  }

  @Test("empty environment → libpq defaults")
  func emptyEnvironmentDefaults() {
    let config = PostgresConnectionConfig(environment: [:])
    #expect(config.host == PostgresConnectionConfig.defaultHost)
    #expect(config.port == PostgresConnectionConfig.defaultPort)
    #expect(config.user == PostgresConnectionConfig.defaultUser)
    // libpq's convention: PGDATABASE unset → same as user.
    #expect(config.database == config.user)
    #expect(config.password == nil)
  }

  @Test("malformed port under prefix falls through to PGPORT")
  func malformedPrefixedPortFallsThroughToLibpq() {
    let config = PostgresConnectionConfig(
      environment: [
        "SHIKKI_DB_PORT": "not-a-number",
        "PGPORT": "6001",
      ],
      firstChoicePrefix: "SHIKKI_DB_"
    )
    #expect(config.port == 6001)
  }

  @Test("malformed port under PGPORT falls through to default")
  func malformedLibpqPortFallsThroughToDefault() {
    let config = PostgresConnectionConfig(environment: ["PGPORT": "garbage"])
    #expect(config.port == PostgresConnectionConfig.defaultPort)
  }

  // MARK: - Explicit init round-trip

  @Test("explicit init carries all five scalars verbatim")
  func explicitInitRoundTrips() {
    let config = PostgresConnectionConfig(
      host: "db.test",
      port: 5555,
      user: "t",
      database: "tdb",
      password: nil
    )
    let asProtocol: any DBConnectionConfiguring = config
    #expect(asProtocol.host == "db.test")
    #expect(asProtocol.port == 5555)
    #expect(asProtocol.user == "t")
    #expect(asProtocol.database == "tdb")
    #expect(asProtocol.password == nil)
  }

  // MARK: - psql invocation seam (BR-BKT-02b)

  @Test("psqlConnectionArguments follows the -h/-p/-U/-d --no-psqlrc shape")
  func psqlArgumentsShape() {
    let config = PostgresConnectionConfig(
      host: "db.local",
      port: 5433,
      user: "shikki",
      database: "shikki",
      password: "should-never-appear"
    )
    let args = config.psqlConnectionArguments
    #expect(
      args == ["-h", "db.local", "-p", "5433", "-U", "shikki", "-d", "shikki", "--no-psqlrc"])
    // The password is deliberately absent from the argument vector so it
    // can never leak into a process listing — pass it via PGPASSWORD.
    #expect(!args.contains("should-never-appear"))
  }
}
