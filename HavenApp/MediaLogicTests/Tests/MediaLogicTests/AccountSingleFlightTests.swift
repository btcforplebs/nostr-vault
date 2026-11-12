import XCTest
@testable import MediaLogic

@MainActor
final class AccountSingleFlightTests: XCTestCase {
    /// Slow work that records which account ran.
    private func work(_ account: String, into log: Log, ms: UInt64 = 100) -> @MainActor () async -> Void {
        { log.ran.append(account); try? await Task.sleep(nanoseconds: ms * 1_000_000) }
    }

    final class Log { var ran: [String] = []; var current = "A" }

    func testSameAccountCallerWaitsInsteadOfRunningAgain() async {
        let flight = AccountSingleFlight(), log = Log()
        async let first: Void = flight.run(account: "A", currentAccount: { "A" }, work("A", into: log))
        try? await Task.sleep(nanoseconds: 20_000_000)
        await flight.run(account: "A", currentAccount: { "A" }, work("A", into: log))
        await first
        XCTAssertEqual(log.ran, ["A"])
    }

    /// Account switch mid-fetch: the waiter for B used to spin forever on
    /// A's finished task (the main actor never yielded). Now it runs B once.
    func testSwitchMidFetchRunsTheNewAccountOnceAndFinishes() async {
        let flight = AccountSingleFlight(), log = Log()
        async let first: Void = flight.run(account: "A", currentAccount: { log.current }, work("A", into: log))
        try? await Task.sleep(nanoseconds: 50_000_000)
        log.current = "B"
        let done = expectation(description: "B finishes")
        Task { @MainActor in
            await flight.run(account: "B", currentAccount: { log.current }, self.work("B", into: log))
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
        await first
        XCTAssertEqual(log.ran, ["A", "B"])
        // The slot is free again: a later call runs.
        await flight.run(account: "B", currentAccount: { log.current }, work("B", into: log, ms: 1))
        XCTAssertEqual(log.ran, ["A", "B", "B"])
    }

    func testWaiterSkipsWhenTheAccountChangedAgain() async {
        let flight = AccountSingleFlight(), log = Log()
        async let first: Void = flight.run(account: "A", currentAccount: { log.current }, work("A", into: log))
        try? await Task.sleep(nanoseconds: 20_000_000)
        log.current = "B"
        let waiter = Task { @MainActor in
            await flight.run(account: "B", currentAccount: { log.current }, self.work("B", into: log))
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        log.current = "C"
        await first
        await waiter.value
        XCTAssertEqual(log.ran, ["A"])
    }
}
