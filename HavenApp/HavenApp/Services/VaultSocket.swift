import Foundation
import Combine
#if os(iOS)
import UIKit
#endif

/// Requests to this device's vault relay at `path` ("" for the main relay,
/// "/lists" for list history, "/private" for drafts), answering the vault's
/// NIP-42 challenge as the owner.
///
/// One socket per path, kept open and shared by every request to that path
/// (VaultSessionCore): it logs in once, not once per request. Each login is
/// a signature, and with a remote signer a round trip to it; one socket per
/// request sent Logen's signer ~34 logins for one list change (2026-11-05).
/// The socket closes after `idleClose` with nothing asked, and when the vault
/// drops it; the next request opens a new one and logs in again.
@MainActor
final class VaultSocket {
    /// Open sessions by vault URL (base + path).
    private static var sessions: [String: VaultSocket] = [:]

    /// How long an unused socket stays open.
    static let idleClose: TimeInterval = 300

    private let client = WebSocketClient()
    private var subs = Set<AnyCancellable>()
    private var core = VaultSessionCore()
    private var waiters: [String: (VaultSessionCore.Outcome) -> Void] = [:]
    private var idleWork: DispatchWorkItem?
    private let url: URL
    private let relayTag: String

    private init(url: URL, relayTag: String) {
        self.url = url
        self.relayTag = relayTag
        client.isTemporary = true
        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .connected: self.apply(self.core.connected())
                case .disconnected, .error: self.apply(self.core.disconnected())
                case .connecting: break
                }
            }
            .store(in: &subs)
        client.messageSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self, let data = text.data(using: .utf8),
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                      let type = arr.first as? String else { return }
                self.apply(self.core.received(type: type, arr))
            }
            .store(in: &subs)
    }

    /// The session for `path`, opened on first use.
    private static func session(path: String) -> VaultSocket? {
        let base = ConfigService.shared.config.nostrURL
        guard let url = URL(string: base + path) else { return nil }
        let key = url.absoluteString
        if let open = sessions[key] { return open }
        watchBackground()
        let made = VaultSocket(url: url, relayTag: base + path)
        sessions[key] = made
        return made
    }

    #if os(iOS)
    private static var backgroundWatch: NSObjectProtocol?
    #endif

    /// iOS kills an app's sockets while it is away, and a killed one still
    /// reads connected: close them on the way out, so coming back opens (and
    /// logs in) once per path instead of each first request timing out.
    private static func watchBackground() {
        #if os(iOS)
        guard backgroundWatch == nil else { return }
        backgroundWatch = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                for session in sessions.values where session.core.isIdle { session.close() }
            }
        }
        #endif
    }

    /// Every event a REQ for `filter` returns, or nil when the vault didn't
    /// finish answering (no EOSE before `timeout`).
    static func query(path: String, filter: [String: Any], timeout: TimeInterval = 8) async -> [NostrEvent]? {
        guard await RelayProcessManager.shared.ensureRelayReady(timeout: 10.0),
              let session = session(path: path) else { return nil }
        let subId = "vault-\(UUID().uuidString.prefix(8))"
        guard let frame = Self.text(["REQ", subId, filter]) else { return nil }
        guard case .events(let raw) = await session.perform(key: subId, kind: .req, frame: frame, timeout: timeout) else { return nil }
        return raw.compactMap { obj in
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
            return try? JSONDecoder().decode(NostrEvent.self, from: data)
        }
    }

    /// Every event for `filter` however many there are: paged newest first
    /// past the vault's answer cap (VaultPaging), on the one session. nil
    /// when a page wasn't answered.
    static func queryAll(path: String, filter: [String: Any], timeout: TimeInterval = 8) async -> [NostrEvent]? {
        var page = filter
        page["limit"] = VaultPaging.limit
        var byID: [String: NostrEvent] = [:]
        for _ in 0..<VaultPaging.maxPages {
            guard let found = await query(path: path, filter: page, timeout: timeout) else { return nil }
            let known = Set(byID.keys)
            for event in found { byID[event.id] = event }
            guard let until = VaultPaging.nextUntil(page: found.map { (id: $0.id, createdAt: Int($0.created_at)) }, known: known) else { break }
            page["until"] = until
        }
        return Array(byID.values)
    }

    /// Sends `event` to the vault and waits for its OK: true only when the
    /// vault accepted it (or already held it).
    static func publish(_ event: NostrEvent, path: String = "", timeout: TimeInterval = 6) async -> Bool {
        guard await RelayProcessManager.shared.ensureRelayReady(timeout: 10.0),
              let encoded = try? JSONEncoder().encode(event),
              let dict = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let frame = Self.text(["EVENT", dict]),
              let session = session(path: path) else { return false }
        guard case .accepted(let ok) = await session.perform(key: event.id, kind: .event, frame: frame, timeout: timeout) else { return false }
        return ok
    }

    // MARK: - Session

    private func perform(key: String, kind: VaultSessionCore.Kind, frame: String, timeout: TimeInterval) async -> VaultSessionCore.Outcome {
        idleWork?.cancel()
        idleWork = nil
        return await withCheckedContinuation { (continuation: CheckedContinuation<VaultSessionCore.Outcome, Never>) in
            // The same key asked again while the first is out (one event
            // published twice at once): submit ends the first, so its effects
            // go before this waiter is set. Nothing in them answers this one
            // (answers come later, off the socket).
            let (token, effects) = core.submit(key: key, kind: kind, frame: frame)
            apply(effects)
            waiters[key] = { continuation.resume(returning: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.apply(self.core.timedOut(key: key, token: token))
            }
        }
    }

    private func apply(_ effects: [VaultSessionCore.Effect]) {
        for effect in effects {
            switch effect {
            case .connect:
                client.connect(url: url)
            case .disconnect:
                client.disconnect()
            case .send(let text):
                client.send(text: text)
            case .signAuth(let challenge):
                signAuth(challenge)
            case .finish(let key, let outcome):
                waiters.removeValue(forKey: key)?(outcome)
            }
        }
        scheduleIdleClose()
    }

    private func signAuth(_ challenge: String) {
        let relayTag = self.relayTag
        Task { @MainActor in
            guard let auth = await NostrService.shared.signEventAsync(
                kind: 22242, content: "",
                tags: [["relay", relayTag], ["challenge", challenge]],
                forceOwner: true
            ), let encoded = try? JSONEncoder().encode(auth),
               let dict = try? JSONSerialization.jsonObject(with: encoded),
               let frame = Self.text(["AUTH", dict]) else {
                // A bunker owner with no session yet (restart with
                // another account active): log it in for next time.
                NIP46Service.shared.connectOwnerInBackgroundIfNeeded()
                self.apply(self.core.authUnavailable())
                return
            }
            self.apply(self.core.authSigned(id: auth.id, frame: frame))
        }
    }

    private func close() {
        idleWork?.cancel()
        idleWork = nil
        guard core.link != .down else { return }
        client.disconnect()
        apply(core.disconnected())
    }

    /// Closes the socket once nothing has been asked of it for `idleClose`.
    private func scheduleIdleClose() {
        guard core.isIdle, core.link != .down, idleWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.idleWork = nil
            guard self.core.isIdle else { return }
            self.close()
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleClose, execute: work)
    }

    private static func text(_ message: [Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
