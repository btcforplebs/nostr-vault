import Foundation
import Combine

/// Requests to this device's vault relay at a path ("" for the main relay,
/// "/lists" for list history, "/private" for drafts), over one socket per
/// path kept for the session and logged in (NIP-42, as the owner) once
/// (VaultLink). A dropped socket is reopened by the next request and logs in
/// once more; a switch of owner opens new ones.
@MainActor
final class VaultSocket {
    private static var open: [String: VaultSocket] = [:]

    private let client = WebSocketClient()
    private var subs = Set<AnyCancellable>()
    private let owner: String
    private var link: VaultLink!

    private init(url: URL, relayTag: String, owner: String) {
        self.owner = owner
        client.isTemporary = true
        let client = self.client
        link = VaultLink(hooks: .init(
            connect: { client.connect(url: url) },
            disconnect: { client.disconnect() },
            send: { message in
                if let data = try? JSONSerialization.data(withJSONObject: message),
                   let text = String(data: data, encoding: .utf8) {
                    client.send(text: text)
                }
            },
            signAuth: { challenge, done in
                Task { @MainActor in
                    guard let auth = await NostrService.shared.signEventAsync(
                        kind: 22242, content: "",
                        tags: [["relay", relayTag], ["challenge", challenge]],
                        forceOwner: true
                    ), let encoded = try? JSONEncoder().encode(auth),
                       let dict = try? JSONSerialization.jsonObject(with: encoded) else {
                        // A bunker owner with no session yet (restart with
                        // another account active): log it in for next time.
                        NIP46Service.shared.connectOwnerInBackgroundIfNeeded()
                        done(nil)
                        return
                    }
                    done((auth.id, dict))
                }
            },
            probe: { done in
                client.probeAlive { alive in DispatchQueue.main.async { done(alive) } }
            },
            after: { seconds, run in DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: run) },
            now: { Date() }
        ))

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .connected: self?.link.didConnect()
                case .error: self?.link.didDrop(error: true)
                case .disconnected: self?.link.didDrop(error: false)
                case .connecting: break
                }
            }
            .store(in: &subs)
        client.messageSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in self?.link.receive(text) }
            .store(in: &subs)
    }

    /// The kept socket for `path`, or nil without a vault URL.
    private static func socket(for path: String) -> VaultSocket? {
        let config = ConfigService.shared.config
        let base = config.nostrURL
        guard let url = URL(string: base + path) else { return nil }
        let owner = config.ownerNpub
        let key = base + path
        if let kept = open[key], kept.owner == owner { return kept }
        open[key]?.link.drop()
        let made = VaultSocket(url: url, relayTag: base + path, owner: owner)
        open[key] = made
        return made
    }

    /// Every event a REQ for `filter` returns, or nil when the vault didn't
    /// finish answering (no EOSE before `timeout`).
    static func query(path: String, filter: [String: Any], timeout: TimeInterval = 8) async -> [NostrEvent]? {
        await query(path: path, filters: [filter], timeout: timeout)
    }

    /// One REQ with several filters, each with its own limit; nil when the
    /// vault didn't finish answering.
    static func query(path: String, filters: [[String: Any]], timeout: TimeInterval = 8) async -> [NostrEvent]? {
        guard await RelayProcessManager.shared.ensureRelayReady(timeout: 10.0),
              let socket = socket(for: path) else { return nil }
        let subId = "vault-\(UUID().uuidString.prefix(8))"
        return await withCheckedContinuation { (continuation: CheckedContinuation<[NostrEvent]?, Never>) in
            var events: [NostrEvent] = []
            socket.link.perform(
                key: subId, message: ["REQ", subId] + filters, close: ["CLOSE", subId], timeout: timeout,
                onMessage: { type, arr in
                    switch type {
                    case "EVENT":
                        if let dict = arr[safe: 2] as? [String: Any],
                           let data = try? JSONSerialization.data(withJSONObject: dict),
                           let event = try? JSONDecoder().decode(NostrEvent.self, from: data) {
                            events.append(event)
                        }
                        return false
                    case "EOSE":
                        continuation.resume(returning: events)
                        return true
                    case "CLOSED":
                        continuation.resume(returning: nil)
                        return true
                    default:
                        return false
                    }
                },
                onFail: { continuation.resume(returning: nil) }
            )
        }
    }

    /// Sends `event` to the vault and waits for its OK: true only when the
    /// vault accepted it (or already held it).
    static func publish(_ event: NostrEvent, path: String = "", timeout: TimeInterval = 6) async -> Bool {
        guard await RelayProcessManager.shared.ensureRelayReady(timeout: 10.0),
              let encoded = try? JSONEncoder().encode(event),
              let dict = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let socket = socket(for: path) else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            socket.link.perform(
                key: event.id, message: ["EVENT", dict], close: nil, timeout: timeout,
                onMessage: { type, arr in
                    guard type == "OK" else { return false }
                    let accepted = (arr[safe: 2] as? Bool) ?? false
                    let reason = (arr[safe: 3] as? String) ?? ""
                    continuation.resume(returning: accepted || reason.hasPrefix("duplicate"))
                    return true
                },
                onFail: { continuation.resume(returning: false) }
            )
        }
    }
}
