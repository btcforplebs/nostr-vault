import XCTest
@testable import MediaLogic

/// First run + the Vault's "Still to bring in" (haven-go import_jobs.go).
final class ImportJobsTests: XCTestCase {
    /// The shape ImportJobsC returns (contract in
    /// PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md), plus a key nobody knows.
    private let json = """
    {"account":"abc","start_date":"2023-01-01","running":"replies","future_key":1,"jobs":[
      {"name":"setup","status":"partial","started_at":1793883564,"ended_at":1793883575,"reason":"ok","stored":812,
       "unread":[{"relay":"wss://nostr.wine/","from":"2023-01-01","to":"2026-11-05","why":"slow"}],"est_seconds":11},
      {"name":"replies","status":"running","stored":0,"unread":[],"est_seconds":180},
      {"name":"older_relays","status":"never","stored":0,"unread":[
        {"relay":"wss://nostr.wine","from":"2023-01-01","to":"2026-11-05","why":"not_read_yet"},
        {"relay":"ws://127.0.0.1:4869/secrettoken","from":"2020-11-01","to":"2026-11-05","why":"unreachable"}],"est_seconds":240},
      {"name":"wider_network","status":"never","stored":0,"unread":null,"est_seconds":90}
    ]}
    """

    func testParsesTheEngineList() throws {
        let list = try XCTUnwrap(ImportJobs.parse(json))
        XCTAssertEqual(list.running, "replies")
        XCTAssertEqual(list.startDate, "2023-01-01")
        XCTAssertEqual(list.jobs.map(\.name), ["setup", "replies", "older_relays", "wider_network"])
        let setup = try XCTUnwrap(list.job("setup"))
        XCTAssertEqual(setup.status, "partial")
        XCTAssertEqual(setup.stored, 812)
        XCTAssertEqual(setup.unread?.first?.why, "slow")
        XCTAssertEqual(list.job("older_relays")?.estSeconds, 240)
        XCTAssertNil(list.job("list_history"))
        XCTAssertNil(ImportJobs.parse("not json"))
        XCTAssertNil(ImportJobs.parse(""))
    }

    func testParsesTheLogLineAndIgnoresUnknownKeys() {
        let line = "2026/11/05 14:00:01 IMPORT_JOB name=setup status=done stored=812 unread=0 new_key=x\r"
        XCTAssertEqual(ImportJobs.parseLine(line), .init(name: "setup", status: "done", stored: 812, unread: 0))
        XCTAssertEqual(ImportJobs.parseLine("IMPORT_JOB status=partial name=older_relays")?.name, "older_relays")
        XCTAssertNil(ImportJobs.parseLine("IMPORT_RESULT status=complete"))
        XCTAssertNil(ImportJobs.parseLine("IMPORT_JOB name= status=done"))
        XCTAssertNil(ImportJobs.parseLine("IMPORT_JOB name=setup"))
    }

    /// The parser sends the line on, not into the old import's state.
    func testRelayLogParserCollectsJobLines() {
        var batch = RelayLogParser.BatchedStateUpdate()
        RelayLogParser.collectStateChanges(from: "IMPORT_JOB name=setup status=running stored=0 unread=0", into: &batch)
        XCTAssertEqual(batch.importJobLines.map(\.status), ["running"])
        XCTAssertTrue(RelayLogParser.isCritical(batch), "must reach the app with the window closed too")
        XCTAssertNil(batch.importStatusMessage)
    }

    /// The user goes in on done or partial, never on anything else.
    func testSetupLetsTheUserInOnDoneOrPartialOnly() {
        XCTAssertEqual(ImportJobs.setupStage(status: "done", reason: nil), .finished(partial: false))
        XCTAssertEqual(ImportJobs.setupStage(status: "partial", reason: "ok"), .finished(partial: true))
        XCTAssertEqual(ImportJobs.setupStage(status: "failed", reason: "no_relay"), .couldNotFinish(reason: "no_relay"))
        XCTAssertEqual(ImportJobs.setupStage(status: "cancelled", reason: nil), .couldNotFinish(reason: nil))
        XCTAssertEqual(ImportJobs.setupStage(status: "running", reason: nil), .running)
        XCTAssertEqual(ImportJobs.setupStage(status: "never", reason: nil), .starting)
        XCTAssertEqual(ImportJobs.setupStage(status: nil, reason: nil), .starting)
    }

    /// The other vault's link carries its token in the path: the card names
    /// it, never prints it.
    func testUnreadLinesNeverShowTheOtherVaultLink() throws {
        let older = try XCTUnwrap(ImportJobs.parse(json)?.job("older_relays"))
        let lines = ImportJobs.unreadLines(older)
        XCTAssertEqual(lines, [
            "nostr.wine: 2023-01-01 to 2026-11-05, not read yet",
            "Your other vault: 2020-11-01 to 2026-11-05, couldn't connect",
        ])
        XCTAssertFalse(lines.joined().contains("secrettoken"))
    }

    func testLeftUnreadMatchesTheRelayWhateverItsSlash() throws {
        let list = try XCTUnwrap(ImportJobs.parse(json))
        XCTAssertTrue(ImportJobs.leftUnread("wss://nostr.wine", in: list.job("setup")))
        XCTAssertFalse(ImportJobs.leftUnread("wss://relay.damus.io", in: list.job("setup")))
        XCTAssertTrue(ImportJobs.leftUnread("ws://127.0.0.1:4869/secrettoken", in: list.job("older_relays")))
        XCTAssertFalse(ImportJobs.leftUnread("wss://nostr.wine", in: nil))
    }

    func testStatusTextNeverSaysDoneForAPartialRun() {
        let now = Date(timeIntervalSince1970: 1_793_890_000)
        var job = ImportJobs.Job(name: "replies", status: "partial")
        job.endedAt = 1_793_883_741
        job.stored = 11266
        let text = ImportJobs.statusText(job, runningNow: false, now: now)
        XCTAssertTrue(text.hasPrefix("Not everything was read."), text)
        XCTAssertFalse(text.contains("Done"), text)
        XCTAssertTrue(text.contains("Last ran"), text)

        let never = ImportJobs.Job(name: "replies", status: "never", estSeconds: 180)
        XCTAssertEqual(ImportJobs.statusText(never, runningNow: false), "Not run yet. About 3 min.")
        XCTAssertEqual(ImportJobs.runTitle(never), "Run")
        XCTAssertEqual(ImportJobs.runTitle(job), "Run again")

        var cut = ImportJobs.Job(name: "older_relays", status: "running")
        cut.reason = "will_resume"
        XCTAssertTrue(ImportJobs.statusText(cut, runningNow: false).hasPrefix("Cut short"))
        XCTAssertTrue(ImportJobs.statusText(cut, runningNow: true).hasPrefix("Bringing it in"))
    }

    func testEstimates() {
        XCTAssertEqual(ImportJobs.estimate(45), "About 45 s")
        XCTAssertEqual(ImportJobs.estimate(90), "About 1.5 min")
        XCTAssertEqual(ImportJobs.estimate(240), "About 4 min")
        XCTAssertNil(ImportJobs.estimate(nil))
        XCTAssertNil(ImportJobs.estimate(0))
    }

    /// The card's items are exactly the engine's Run-only jobs.
    func testCardJobsAreTheRunOnlyJobs() {
        XCTAssertEqual(ImportJobs.cardJobs, ["replies", "older_relays", "wider_network", "list_history"])
        XCTAssertFalse(ImportJobs.cardJobs.contains(ImportJobs.setup))
    }
}
