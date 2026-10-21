import Foundation
import Security
#if os(iOS)
import UIKit
#endif

extension NIP46Service {
    // MARK: - Private: Go Bridge Helper

    nonisolated func callGo(_ block: @escaping @Sendable () -> UnsafeMutablePointer<CChar>?) async throws -> String {
        let result: String? = await Task.detached {
            guard let cStr = block() else { return nil }
            let str = String(cString: cStr)
            free(cStr)
            return str
        }.value
        guard let result else {
            throw Self.lastBridgeError() ?? NIP46Error.signerError("Go bridge returned nil")
        }
        return result
    }

    /// Why the last NIP-46 bridge call returned nil, as classified by the Go
    /// side (`NIP46LastErrorC`). Nil when it recorded nothing.
    nonisolated static func lastBridgeError() -> NIP46Error? {
        guard let cStr = NIP46LastErrorC() else { return nil }
        let raw = String(cString: cStr)
        free(cStr)
        switch raw {
        case "": return nil
        case "timeout": return .timeout
        case "disconnected": return .notConnected
        case "offline": return .offline
        default:
            if raw.hasPrefix("rejected:") { return .rejected(String(raw.dropFirst("rejected:".count))) }
            if raw.hasPrefix("error:") { return .signerError(String(raw.dropFirst("error:".count))) }
            return .signerError(raw)
        }
    }

    /// Kinds a person signs by doing something (posting, reacting, following,
    /// sending a DM — kind 13 is the DM seal). Everything else the app signs on
    /// its own — relay AUTH (22242), Blossom and HTTP auth (24242, 27235),
    /// list syncs — and waits in the background queue.
    private static let userActionKinds: Set<Int> = [0, 1, 3, 5, 6, 7, 9, 13, 16, 20, 21, 22, 1111, 1984, 9734, 10015, 30023]

    /// Upload auth: Blossom (24242) and HTTP auth (27235). Signed without a
    /// banner like other background work, but almost always because the person
    /// just attached a photo, so it skips the background queue. Queued, a photo
    /// post waited silently behind relay AUTH and DM decrypts.
    private static let uploadAuthKinds: Set<Int> = [24242, 27235]

    private nonisolated static func kind(ofEventJSON json: String) -> Int? {
        struct KindOnly: Decodable { let kind: Int }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(KindOnly.self, from: data).kind
    }

    nonisolated static func isUserAction(eventJSON json: String) -> Bool {
        guard let kind = kind(ofEventJSON: json) else { return false }
        return userActionKinds.contains(kind)
    }

    nonisolated static func waitsInBackgroundQueue(eventJSON json: String) -> Bool {
        guard let kind = kind(ofEventJSON: json) else { return true }
        return !uploadAuthKinds.contains(kind)
    }

    /// Runs one request to the signer, keeping the app alive in the background
    /// while it is outstanding so switching to the signer to approve doesn't
    /// kill it.
    ///
    /// No "approve in your signer" banner: it could not tell a prompt from an
    /// auto-approve on a slow relay, so it went up for nearly every action and
    /// stayed until the slowest one answered. The signer prompts on its own,
    /// and a rejection or timeout surfaces as an error.
    ///
    /// - Parameter userAction: true for something the person did (a post, a
    ///   reaction); false for background work (decrypting the DM backlog,
    ///   relay AUTH).
    func signerRequest<T>(userAction: Bool, queued: Bool = true, _ body: @escaping () async throws -> T) async throws -> T {
        // Background work (decrypting the DM backlog, relay AUTH, Blossom auth,
        // list syncs) goes to the signer one request at a time, however many
        // callers ask at once. Things the person did (userAction) skip the
        // queue so a post never waits behind a backlog.
        //
        // A request holds the queue for at most `backgroundLease`. The signer can
        // leave one unanswered for the full 90 s bridge timeout (relay AUTH after
        // the app comes back to the foreground does this), and everything behind
        // it used to wait the whole time. Past the lease the request keeps
        // waiting for its answer, it just stops holding up the rest.
        let gated = !userAction && queued
        var ticket: UInt64?
        if gated {
            let held = await Self.backgroundGate.wait()
            ticket = held
            Task {
                try? await Task.sleep(nanoseconds: Self.backgroundLease)
                await Self.backgroundGate.signal(held)
            }
        }
        defer { if let ticket { Task { await Self.backgroundGate.signal(ticket) } } }
        outstandingRequests += 1
        // A signer can answer any request with an auth challenge; look for one
        // only while something is waiting on the signer.
        if authPollerTask == nil { startAuthURLPoller() }
        #if os(iOS)
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "NIP46Request") {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        #endif
        defer {
            outstandingRequests -= 1
            if outstandingRequests == 0 && connectionState != .connecting { stopAuthURLPoller() }
            #if os(iOS)
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
            #endif
        }
        let answer = try await body()
        lastSignerAnswer = Date()
        return answer
    }

    // MARK: - Auth URL Polling

    func startAuthURLPoller() {
        authPollerTask?.cancel()
        authPollerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { break }
                checkPendingAuthURL()
            }
        }
    }

    /// Polling stops when nothing waits on the signer. It used to run every
    /// 0.5 s from the first connect for the life of the app.
    func stopAuthURLPoller() {
        authPollerTask?.cancel()
        authPollerTask = nil
    }

    func checkPendingAuthURL() {
        guard let cStr = NIP46GetPendingAuthURLC() else { return }
        let url = String(cString: cStr)
        free(cStr)
        guard !url.isEmpty else { return }
        authChallengeURL = url
        RelayProcessManager.shared.addLog("NIP-46: Auth challenge: \(url)", level: "INFO")
    }

    // MARK: - Keepalive
    //
    // There is none, on purpose. A kind 24133 `ping` is a request like any
    // other: it crosses the relay and wakes the signer app. The old 60 s loop
    // sent one every minute the app was open and then did nothing with the
    // answer — a failure no longer drops the session, because a signer app
    // asleep on the phone misses pings. go-nostr's pool redials a dropped
    // socket and re-subscribes for replies on its own, and a session that is
    // genuinely gone is found by `recheckSession` on the first request that
    // goes unanswered. So the loop was pure traffic to the person's signer.
}
