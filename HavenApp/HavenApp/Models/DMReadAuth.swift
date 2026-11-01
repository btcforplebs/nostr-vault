import Foundation

/// NIP-42 on one connection that reads DMs. Some DM relays (relay.damus.io,
/// nostr.wine, a Haven inbox) hand gift wraps only to the reader they are
/// addressed to: the REQ is closed with "auth-required: …" until the reader
/// AUTHs. The external DM fetch only handled EVENT, so whatever a stranger
/// sent only to such a relay never reached Requests (11-01).
///
/// One AUTH per connection at most, never a loop: a relay that turns the AUTH
/// down, or closes the REQ again after accepting it, is given up on, and the
/// caller remembers that for the rest of the app session (`mayAuth` false) so
/// a remote signer is not asked again on every foreground.
///
/// Free of app types so `MediaLogicTests` can compile it.
struct DMReadAuth {
    enum Step: Equatable {
        case none
        /// Sign a kind 22242 for this challenge and hand its id to `authSent`.
        case sign(challenge: String)
        /// The AUTH was accepted: send these REQs again.
        case resend([String])
        /// Stop asking this relay for the session.
        case giveUp(String)
    }

    private enum Phase: Equatable { case idle, signing, sent(String), accepted, done }

    let mayAuth: Bool
    private(set) var challenge: String?
    private var phase: Phase = .idle
    private var reqs: [String: String] = [:]   // sub id -> REQ text
    private var waiting: [String] = []          // sub ids closed for auth, in order

    init(mayAuth: Bool) { self.mayAuth = mayAuth }

    /// True while an AUTH is being signed or answered: the connection should
    /// stay open a little longer than a plain read.
    var isAuthenticating: Bool {
        switch phase {
        case .signing, .sent: return true
        default: return false
        }
    }

    /// Remember a REQ so it can be sent again after the AUTH.
    mutating func sent(subId: String, req: String) { reqs[subId] = req }

    /// Feed every non-EVENT frame from the relay through here.
    mutating func receive(type: String, json: [Any]) -> Step {
        switch type {
        case "AUTH":
            guard let value = json.count > 1 ? json[1] as? String : nil, !value.isEmpty else { return .none }
            challenge = value
            return startIfReady()
        case "CLOSED":
            guard let subId = json.count > 1 ? json[1] as? String : nil, reqs[subId] != nil else { return .none }
            let reason = (json.count > 2 ? json[2] as? String : nil) ?? ""
            guard reason.hasPrefix("auth-required") else { return .none }
            switch phase {
            case .accepted:
                // Closed again after the relay let us in: AUTH can't help here.
                phase = .done
                return .giveUp("still closed after AUTH: \(reason)")
            case .done:
                return .none
            case .idle, .signing, .sent:
                if !waiting.contains(subId) { waiting.append(subId) }
                return startIfReady()
            }
        case "OK":
            guard case .sent(let authId) = phase,
                  let id = json.count > 1 ? json[1] as? String : nil, id == authId else { return .none }
            let accepted = (json.count > 2 ? json[2] as? Bool : nil) ?? false
            guard accepted else {
                phase = .done
                let note = (json.count > 3 ? json[3] as? String : nil) ?? ""
                return .giveUp("AUTH refused: \(note)")
            }
            phase = .accepted
            let again = waiting.compactMap { reqs[$0] }
            waiting = []
            return .resend(again)
        default:
            return .none
        }
    }

    /// The signed AUTH went to the relay.
    mutating func authSent(id: String) {
        guard phase == .signing else { return }
        phase = .sent(id)
    }

    /// The signer didn't sign (declined, timed out, account switched).
    mutating func signFailed() -> Step {
        guard phase == .signing else { return .none }
        phase = .done
        return .giveUp("not signed")
    }

    private mutating func startIfReady() -> Step {
        guard mayAuth, phase == .idle, !waiting.isEmpty, let challenge else { return .none }
        phase = .signing
        return .sign(challenge: challenge)
    }

    /// Where the external DM fetch looks, in order: your DM inbox relays
    /// first (where DMs to you are published), then the feed's read relays,
    /// then anything else. Duplicates dropped, capped at `cap`. Read relays
    /// used to come first, so a long feed list cut the DM relays off.
    static func fetchRelays(_ groups: [[String]], cap: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for relay in groups.joined() where out.count < cap {
            let key = relay.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(relay)
        }
        return out
    }
}
