import XCTest
@testable import MediaLogic

/// Signer audit 2026-11-05 #5 (RESEARCH/NV_SIGNER_AUDIT_2026_11_05.md): with a
/// bunker, DMs asked for the vault login on every return to the app and in
/// Background App Refresh, and asked again about wraps the signer had refused.
final class DMSignerPolicyTests: XCTestCase {

    // MARK: When a signer may be asked

    func testABunkerIsNeverAskedWithTheAppClosed() {
        XCTAssertFalse(DMSignerPolicy.mayAskSigner(needsPerson: true, appActive: false))
        XCTAssertTrue(DMSignerPolicy.mayAskSigner(needsPerson: true, appActive: true))
        // The user's own tap (Retry) may.
        XCTAssertTrue(DMSignerPolicy.mayAskSigner(needsPerson: true, appActive: false, userAsked: true))
        // A local key never needs a person: unchanged in the background.
        XCTAssertTrue(DMSignerPolicy.mayAskSigner(needsPerson: false, appActive: false))
    }

    func testTheOutsideFetchRunsAtMostEveryFiveMinutes() {
        let now: Int64 = 1_800_000_000
        XCTAssertFalse(DMSignerPolicy.fetchDue(lastFetch: now - 60, now: now))
        XCTAssertFalse(DMSignerPolicy.fetchDue(lastFetch: now - 300, now: now))
        XCTAssertTrue(DMSignerPolicy.fetchDue(lastFetch: now - 301, now: now))
        XCTAssertTrue(DMSignerPolicy.fetchDue(lastFetch: 0, now: now))
    }

    // MARK: Refused wraps

    /// The DM queue as DMService runs it: each wrap goes through the refused
    /// check, then the parked gate; `asks` counts signer requests.
    private struct Queue {
        var gate = SignerWaitGate()
        var refused = DMRefusedWraps()
        var waiting: [String] = []
        var asks = 0
        /// What the signer does with each id: "open", "refuse" or "silent".
        var signer: [String: String]

        mutating func process(_ id: String) {
            guard refused.mayAsk(id), gate.mayAsk(id) else { waiting.append(id); return }
            asks += 1
            switch signer[id] ?? "open" {
            case "open":
                refused.answered(id)
                if gate.answered(id) { release() }
            case "refuse":
                refused.refused(id)
                waiting.append(id)
                if gate.answered(id) { release() }
            default:
                gate.noAnswer()
                waiting.append(id)
            }
        }

        mutating func release() {
            let all = waiting
            waiting = []
            for id in all { process(id) }
        }

        /// DMService.retryWaitingForSigner(userAsked:)
        mutating func round(userAsked: Bool) {
            guard !waiting.isEmpty else { return }
            if userAsked { refused.userAskedAgain() }
            if gate.parked, let probe = waiting.last(where: { userAsked || !refused.isRefused($0) }) {
                waiting.removeAll { $0 == probe }
                gate.probe(probe)
                process(probe)
            } else {
                release()
            }
        }
    }

    func testARefusedWrapIsNotAskedAgainOnEveryReturnToTheApp() {
        var q = Queue(signer: ["w1": "refuse"])
        q.process("w1")
        XCTAssertEqual(q.asks, 1)
        for _ in 0..<10 { q.round(userAsked: false) }  // ten returns to the app
        XCTAssertEqual(q.asks, 1, "a refusal is asked about again only by Retry")
        XCTAssertEqual(q.waiting, ["w1"], "kept, not lost")
        // The same wrap served again by the relay (a refresh): still not asked.
        q.waiting.removeAll()
        q.process("w1")
        XCTAssertEqual(q.asks, 1)
        // Retry asks once more.
        q.round(userAsked: true)
        XCTAssertEqual(q.asks, 2)
        q.round(userAsked: false)
        XCTAssertEqual(q.asks, 2, "Retry allowed one more ask, not a new loop")
    }

    func testAfterRetryOpensItTheWrapIsDone() {
        var q = Queue(signer: ["w1": "refuse"])
        q.process("w1")
        q.signer["w1"] = "open"
        q.round(userAsked: true)
        XCTAssertTrue(q.waiting.isEmpty)
        XCTAssertFalse(q.refused.isRefused("w1"))
    }

    /// A refused wrap must never be the probe of a parked queue: it would wait
    /// unasked and keep every other wrap waiting behind it.
    func testARefusedWrapDoesNotHoldUpTheOthers() {
        var q = Queue(signer: ["r": "refuse", "a": "silent", "b": "silent"])
        q.process("r")
        q.process("a")
        q.process("b")
        XCTAssertTrue(q.gate.parked)
        q.signer["a"] = "open"
        q.signer["b"] = "open"
        q.round(userAsked: false)
        q.round(userAsked: false)
        XCTAssertEqual(Set(q.waiting), ["r"], "the signer is back: everything but the refusal opened")
    }

    // MARK: The wiring in DMService and the Background App Refresh

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(_ text: String, after marker: String, until end: String = "\n    }\n") throws -> Substring {
        let start = try XCTUnwrap(text.range(of: marker), marker)
        let rest = text[start.upperBound...]
        let stop = rest.range(of: end)?.lowerBound ?? rest.endIndex
        return rest[..<stop]
    }

    /// Background App Refresh asks no signer: it calls the background sync,
    /// never refresh() and never the foreground one.
    func testBackgroundAppRefreshCallsTheBackgroundSync() throws {
        let app = try source("HavenApp-iOS/AppDelegate.swift")
        let task = try body(app, after: "static func handleAppRefreshTask(")
        XCTAssertTrue(task.contains("DMService.shared.syncInBackground()"))
        XCTAssertFalse(task.contains("DMService.shared.syncOnForeground()"))
        XCTAssertFalse(task.contains("DMService.shared.refresh()"))
    }

    /// A return to the app keeps the 5-minute guard and asks only what got
    /// no answer (not refusals).
    func testRefreshKeepsTheGuardAndLeavesRefusalsForRetry() throws {
        let conv = try source("HavenApp/Services/DM/DMService+Conversations.swift")
        let refresh = try body(conv, after: "func refresh() {")
        XCTAssertTrue(refresh.contains("retryWaitingForSigner(userAsked: false)"))
        XCTAssertTrue(refresh.contains("syncOnForeground()"))
        XCTAssertFalse(refresh.contains("fetchFromExternalRelays()"), "refresh skipped the 5-minute guard")
        let sync = try body(conv, after: "func syncOnForeground() {")
        XCTAssertTrue(sync.contains("DMSignerPolicy.fetchDue("))
    }

    /// Becoming active resumes only work that was held (not after Control
    /// Center or an alert), and a held NIP-04 DM gets a fresh REQ: a live
    /// inbox socket would not serve it again.
    func testResumeRunsOnlyAfterAHoldAndReRequestsNIP04() throws {
        let conv = try source("HavenApp/Services/DM/DMService+Conversations.swift")
        let resume = try body(conv, after: "func resumeSignerWorkInFront() {")
        let guardHeld = try XCTUnwrap(resume.range(of: "guard signerWorkHeld else { return }"))
        let retry = try XCTUnwrap(resume.range(of: "retryWaitingForSigner(userAsked: false)"))
        XCTAssertLessThan(guardHeld.lowerBound, retry.lowerBound)
        XCTAssertTrue(resume.contains("startNIP04Listening()"))
        XCTAssertFalse(resume.contains("restartNIP04IfNeeded()"), "a live socket keeps the held DM unshown")

        let wrap = try source("HavenApp/Services/DM/DMService+GiftWrap.swift")
        let process = try body(wrap, after: "private func processGiftWrap(")
        XCTAssertTrue(process.contains("guard mayAskActiveSigner else {\n            signerWorkHeld = true"))
        let processing = try source("HavenApp/Services/DM/DMService+MessageProcessing.swift")
        let nip04 = try body(processing, after: "func handleIncomingNIP04(")
        XCTAssertTrue(nip04.contains("nip04HeldForSigner = true\n            signerWorkHeld = true"))
        let auth = try body(processing, after: "private func handleAuthChallenge(")
        let authHold = try body(String(auth), after: "guard mayAskOwnerSigner else {", until: "return")
        XCTAssertTrue(authHold.contains("signerWorkHeld = true"))
        // An automatic round skipped while not active (refresh before .active,
        // the backoff timer in the background) is resumed in front.
        let retryRound = try body(wrap, after: "func retryWaitingForSigner(")
        let skipped = try body(String(retryRound), after: "} else if !mayAskActiveSigner {", until: "return")
        XCTAssertTrue(skipped.contains("signerWorkHeld = true"))
    }

    /// Every place the DM code asks a signer checks first.
    func testEveryPromptPointChecksTheAppIsInFront() throws {
        let wrap = try source("HavenApp/Services/DM/DMService+GiftWrap.swift")
        let process = try body(wrap, after: "private func processGiftWrap(")
        let check = try XCTUnwrap(process.range(of: "guard mayAskActiveSigner else"))
        let refused = try XCTUnwrap(process.range(of: "guard refusedWraps.mayAsk(event.id) else"))
        let decrypt = try XCTUnwrap(process.range(of: "NIP17Service"))
        XCTAssertLessThan(check.lowerBound, decrypt.lowerBound)
        XCTAssertLessThan(refused.lowerBound, decrypt.lowerBound)
        // The backoff timer's round is automatic.
        XCTAssertTrue(wrap.contains("self.retryWaitingForSigner(userAsked: false)"))
        XCTAssertTrue(wrap.contains("} else if !mayAskActiveSigner {"))

        let processing = try source("HavenApp/Services/DM/DMService+MessageProcessing.swift")
        let auth = try body(processing, after: "private func handleAuthChallenge(")
        let authCheck = try XCTUnwrap(auth.range(of: "guard mayAskOwnerSigner else"))
        let sign = try XCTUnwrap(auth.range(of: "signEventAsync(kind: 22242"))
        XCTAssertLessThan(authCheck.lowerBound, sign.lowerBound)
        let nip04 = try body(processing, after: "func handleIncomingNIP04(")
        let nip04Check = try XCTUnwrap(nip04.range(of: "guard mayAskActiveSigner else"))
        let seen = try XCTUnwrap(nip04.range(of: "seenGiftWrapIds.insert(event.id)"))
        XCTAssertLessThan(nip04Check.lowerBound, seen.lowerBound, "a held NIP-04 DM must not be marked seen")

        let fetch = try source("HavenApp/Services/DM/DMService+ExternalFetch.swift")
        let apply = try body(fetch, after: "case .sign(let challenge):", until: "case .resend")
        let readCheck = try XCTUnwrap(apply.range(of: "guard mayAskActiveSigner else { return }"))
        let readSign = try XCTUnwrap(apply.range(of: "signRelayAuth("))
        XCTAssertLessThan(readCheck.lowerBound, readSign.lowerBound)
    }
}
