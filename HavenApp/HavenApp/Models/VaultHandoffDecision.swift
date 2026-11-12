import Foundation

/// Sync pick 1 (Logen, 2026-11-12): the vault sends the phone's posts, and
/// exactly one device blasts each note. The phone hands a note to its vault
/// over the mesh (VaultPublishHandoff) and holds it for at most `hold`. The
/// vault answers `["OK", id, true, ""]` only when it stored the note and
/// queued its blast (haven-go mesh_publish.go), and only on a connection
/// whose first frame was `["NOTICE", publishNotice]`; every other outcome
/// means the vault will not send it, so the phone does. An older vault, or
/// one that let the phone in as a stranger, stores the note without sending
/// it and never says the notice.
enum VaultHandoffDecision: Equatable {
    case vaultSends
    case phoneSends

    /// How long the phone waits for the vault's OK before sending itself.
    static let hold: TimeInterval = 10

    /// A publish connection's first frame names this (Go meshPublishNotice).
    static let publishNotice = "publish-for-me: on"

    /// The vault's OK for one note.
    struct OKAnswer: Equatable {
        let accepted: Bool
        let message: String
    }

    /// `sawPublishNotice`: the connection's first frame was the notice.
    /// `connected`: the publish connection opened (no refused dial, no
    /// 401/403/409 upgrade). `accepted`/`message`: the vault's OK for the
    /// note, nil when none came. `timedOut`: the hold ran out first.
    /// Only a plain OK true in time hands the blast to the vault; an OK true
    /// with a message (khatru's "duplicate:") is not a queued blast.
    static func decide(sawPublishNotice: Bool, connected: Bool, accepted: Bool?, message: String?,
                       timedOut: Bool) -> VaultHandoffDecision {
        guard sawPublishNotice, connected, !timedOut, accepted == true else { return .phoneSends }
        let said = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? .vaultSends : .phoneSends
    }

    /// True when `frame` is exactly `["NOTICE", publishNotice]`.
    static func isPublishNotice(frame: String) -> Bool {
        guard let data = frame.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count == 2, json[0] as? String == "NOTICE" else { return false }
        return json[1] as? String == publishNotice
    }

    /// The OK for `eventId` in a relay frame, or nil for any other frame.
    static func okAnswer(frame: String, eventId: String) -> OKAnswer? {
        guard let data = frame.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 3, json[0] as? String == "OK", json[1] as? String == eventId,
              let accepted = json[2] as? Bool else { return nil }
        return OKAnswer(accepted: accepted, message: json.count >= 4 ? (json[3] as? String ?? "") : "")
    }
}
