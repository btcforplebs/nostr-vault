import Foundation

/// "Leave Nostr Forever" (Settings › Advanced): the owner leaves Nostr from
/// this device. (Delete Account, on each account's page, sends nothing:
/// `AccountDataSweep`, `ConfigService.removeAccount`.) The rules here are pure so they are unit-tested; LeaveNostrService
/// runs them and LeaveNostrForeverView shows them.
///
/// Order, and why:
/// 1. A blank profile (kind 0) is signed and sent first. Relays that ignore
///    the erase request keep it, so people see the account is gone.
/// 2. The erase request (NIP-62 kind 62, tag `relay` = `ALL_RELAYS`) is signed
///    and sent after it. Relays that honour it erase every event of the key
///    up to its time, the blank profile included.
/// 3. Only then is this device's copy deleted (the factory reset).
enum LeaveNostr {
    /// What the person must type to unlock the button.
    static let confirmWord = "DELETE"

    /// Exactly `DELETE` (spaces around it allowed, any other letters not).
    static func confirms(_ typed: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines) == confirmWord
    }

    /// The last of the three Leave Nostr Forever screens: the account's name
    /// is typed, then the button is held this long.
    static let holdSeconds: Double = 3

    /// What the person types on the last screen: the account's shown name,
    /// or the start of its npub when it has no name.
    static func nameToType(name: String, npub: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(npub.prefix(12)) : trimmed
    }

    /// The typed text matches the name (spaces around it and letter case
    /// ignored). An empty name never matches.
    static func nameConfirms(_ typed: String, expected: String) -> Bool {
        let want = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty else { return false }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(want) == .orderedSame
    }

    /// Shown when the vault stayed busy (import or backup) so the wipe did
    /// not start. Whatever was already sent to relays stays sent.
    static let wipeRefusedText = "The vault is still busy (an import or backup), so nothing on this device was deleted yet. Wait for it to finish, then try again."

    /// NIP-62 "Request to Vanish": every relay that sees it is asked to erase.
    static let vanishKind = 62
    static let vanishTags: [[String]] = [["relay", "ALL_RELAYS"]]
    static let vanishContent = "This account was deleted from Nostr Vault."

    /// The blank profile: every field empty, plus the `deleted` flag some
    /// clients read.
    static let blankProfileContent: String = {
        let fields: [String: Any] = [
            "name": "", "display_name": "", "about": "", "picture": "", "banner": "",
            "website": "", "nip05": "", "lud16": "", "lud06": "", "deleted": true,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }()

    /// Every relay this device uses for the account: where it writes, where it
    /// reads, its DM inbox and its own public relays. wss:// and ws://, each
    /// once. Left out: blocked ones (the Never connect rule) and this device's
    /// own loopback (the vault here gets both events directly).
    static func relays(write: [String], read: [String], dm: [String], own: [String], blocked: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in own + write + read + dm {
            let url = HavenConfig.normalizedRelayURL(raw)
            guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
                  scheme == "wss" || scheme == "ws", let host = parsed.host?.lowercased(), !host.isEmpty,
                  !loopbackHosts.contains(host),
                  !RelayBlocklist.isBlocked(url, in: blocked),
                  seen.insert(url.lowercased()).inserted else { continue }
            out.append(url)
        }
        return out
    }

    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    /// Whether a signed reply may be sent: it is the owner's key, the right
    /// kind and the content asked for. A signer that answers with another key
    /// (or edits the event) gets nothing sent and nothing deleted.
    /// Every tag asked for must be in the signed event (the app may add its
    /// own client tag, so extra tags are allowed).
    static func signedAsAsked(pubkey: String, kind: Int, content: String, tags: [[String]],
                              ownerHex: String, askedKind: Int, askedContent: String, askedTags: [[String]]) -> Bool {
        !ownerHex.isEmpty && pubkey.lowercased() == ownerHex.lowercased()
            && kind == askedKind && content == askedContent
            && askedTags.allSatisfy { tags.contains($0) }
    }

    /// Whether the wipe may go ahead on its own: at least one relay took the
    /// erase request. With none (offline, say), deleting the key now would mean
    /// the request can never be sent again, so the person chooses.
    static func mayWipe(after tally: Tally) -> Bool { !tally.accepted.isEmpty }

    /// The broadcaster's results for a relay that never answered (not a no).
    static let unanswered: Set<String> = ["timeout", "connection failed"]

    /// How many relays said OK, for the line shown before the wipe.
    struct Tally: Equatable {
        var accepted: [String] = []
        var refused: [String] = []
        var total: Int

        var summary: String {
            let silent = max(total - accepted.count - refused.count, 0)
            var parts = ["\(accepted.count) of \(total) relays accepted the erase request"]
            if !refused.isEmpty { parts.append("\(refused.count) refused") }
            if silent > 0 { parts.append("\(silent) did not answer") }
            return parts.joined(separator: ", ")
        }
    }
}
