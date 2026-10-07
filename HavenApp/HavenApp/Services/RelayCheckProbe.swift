import Foundation
import Combine

/// Asks one relay for one of `pubkey`'s notes and times the answer, for the
/// "I use Nostr" relay check (`RelayCheck`). Same socket pattern as
/// `NostrService.lookupNewestReplaceable`, one relay at a time so each gets
/// its own clock.
@MainActor
enum RelayCheckProbe {
    static func check(url: String, pubkey: String, timeout: TimeInterval = RelayCheck.timeout) async -> RelayCheck.Result {
        guard let target = URL(string: url) else { return .notAnswering }
        let started = Date()
        return await withCheckedContinuation { (continuation: CheckedContinuation<RelayCheck.Result, Never>) in
            let client = WebSocketClient()
            client.isTemporary = true
            let subId = "check-\(UUID().uuidString.prefix(6))"
            var subs = Set<AnyCancellable>()
            var hasNotes = false
            var done = false

            func finish(_ result: RelayCheck.Result) {
                guard !done else { return }
                done = true
                client.disconnect()
                subs.removeAll()
                continuation.resume(returning: result)
            }

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { message in
                    guard let data = message.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = json.first as? String,
                          json[safe: 1] as? String == subId else { return }
                    if type == "EVENT" {
                        hasNotes = true
                    } else if type == "EOSE" || type == "CLOSED" {
                        let seconds = Date().timeIntervalSince(started)
                        finish(type == "EOSE"
                               ? RelayCheck.Result(answeredAfter: seconds, hasNotes: hasNotes)
                               : .refused)
                    }
                }
                .store(in: &subs)
            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    guard state == .connected else { return }
                    let req = ["REQ", subId, ["kinds": [1], "authors": [pubkey], "limit": 1]] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let text = String(data: data, encoding: .utf8) {
                        client.send(text: text)
                    }
                }
                .store(in: &subs)
            client.connect(url: target)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(.notAnswering) }
        }
    }
}
