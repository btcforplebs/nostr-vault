import Foundation
import Combine

/// One short request to this device's vault relay at `path` ("" for the main
/// relay, "/lists" for list history, "/private" for drafts), answering a
/// NIP-42 challenge as the owner when the relay sends one and sending again
/// only after the vault's OK for that AUTH (see VaultAuthGate).
@MainActor
final class VaultSocket {
    private let client = WebSocketClient()
    private var subs = Set<AnyCancellable>()
    private var done = false

    private init() { client.isTemporary = true }

    /// Every event a REQ for `filter` returns, or nil when the vault didn't
    /// finish answering (no EOSE before `timeout`).
    static func query(path: String, filter: [String: Any], timeout: TimeInterval = 8) async -> [NostrEvent]? {
        guard await RelayProcessManager.shared.ensureRelayReady(timeout: 10.0) else { return nil }
        let socket = VaultSocket()
        return await socket.run(path: path, timeout: timeout) { send, finish in
            let subId = "vault-\(UUID().uuidString.prefix(8))"
            var events: [NostrEvent] = []
            let sendReq = { send(["REQ", subId, filter]) }
            return (sendReq, { type, arr in
                if type == "EVENT", let dict = arr[safe: 2] as? [String: Any],
                   let data = try? JSONSerialization.data(withJSONObject: dict),
                   let event = try? JSONDecoder().decode(NostrEvent.self, from: data) {
                    events.append(event)
                } else if type == "EOSE" {
                    finish(events)
                } else if type == "CLOSED" {
                    finish(nil)
                }
            })
        }
    }

    /// Sends `event` to the vault and waits for its OK: true only when the
    /// vault accepted it (or already held it).
    static func publish(_ event: NostrEvent, path: String = "", timeout: TimeInterval = 6) async -> Bool {
        guard await RelayProcessManager.shared.ensureRelayReady(timeout: 10.0),
              let encoded = try? JSONEncoder().encode(event),
              let dict = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return false }
        let socket = VaultSocket()
        let ok: Bool? = await socket.run(path: path, timeout: timeout) { send, finish in
            ({ send(["EVENT", dict]) }, { type, arr in
                guard type == "OK", arr[safe: 1] as? String == event.id else { return }
                let accepted = (arr[safe: 2] as? Bool) ?? false
                let reason = (arr[safe: 3] as? String) ?? ""
                finish(accepted || reason.hasPrefix("duplicate"))
            })
        }
        return ok ?? false
    }

    /// Connects, calls `setup` for what to send and how to read answers,
    /// resends once the vault accepts our AUTH, and returns what `finish` was given (nil on
    /// timeout).
    private func run<T>(path: String, timeout: TimeInterval,
                        setup: (_ send: @escaping ([Any]) -> Void, _ finish: @escaping (T?) -> Void)
                            -> (start: () -> Void, read: (String, [Any]) -> Void)) async -> T? {
        let base = ConfigService.shared.config.nostrURL
        guard let url = URL(string: base + path) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let client = self.client
            let send: ([Any]) -> Void = { message in
                if let data = try? JSONSerialization.data(withJSONObject: message),
                   let text = String(data: data, encoding: .utf8) {
                    client.send(text: text)
                }
            }
            let finish: (T?) -> Void = { [weak self] value in
                guard let self, !self.done else { return }
                self.done = true
                client.disconnect()
                self.subs.removeAll()
                continuation.resume(returning: value)
            }
            let (start, read) = setup(send, finish)
            var gate = VaultAuthGate()

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in if state == .connected { start() } }
                .store(in: &subs)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { text in
                    guard let data = text.data(using: .utf8),
                          let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = arr.first as? String else { return }
                    if type == "AUTH" {
                        guard let challenge = arr[safe: 1] as? String, gate.challenge() else { return }
                        Task { @MainActor in
                            guard let auth = await NostrService.shared.signEventAsync(
                                kind: 22242, content: "",
                                tags: [["relay", base + path], ["challenge", challenge]],
                                forceOwner: true
                            ), let encoded = try? JSONEncoder().encode(auth),
                               let dict = try? JSONSerialization.jsonObject(with: encoded) else {
                                // A bunker owner with no session yet (restart with
                                // another account active): log it in for next time.
                                NIP46Service.shared.connectOwnerInBackgroundIfNeeded()
                                finish(nil)
                                return
                            }
                            gate.sentAuth(id: auth.id)
                            send(["AUTH", dict])
                            // No start() here: the vault checks each message on
                            // its own, so a request sent right behind the AUTH
                            // is refused. It goes again on the AUTH's OK.
                        }
                        return
                    }
                    switch gate.handle(type: type, arr) {
                    case .pass: read(type, arr)
                    case .start: start()
                    case .fail: finish(nil)
                    case .ignore: break
                    }
                }
                .store(in: &subs)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
            client.connect(url: url)
        }
    }
}
