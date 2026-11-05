import Foundation

/// The one line haven-go prints at the end of every import cycle
/// (haven-go/import_result.go), and the only thing that may call an import
/// done. A failed, cut or cancelled import used to end as "Import Complete!"
/// on every platform (RESEARCH/NV_IMPORT_AUDIT_*_2026_11_05.md):
///
///     IMPORT_RESULT status=partial reason=walk_deadline,relay_dropped owner=812 tagged=40 relays=3/4 other_vault=none
///
/// Pure Foundation so MediaLogicTests can test it.
struct ImportResult: Equatable {
    enum Status: String {
        case complete, partial, failed, cancelled
    }

    let status: Status
    let reasons: [String]
    let owner: Int
    let tagged: Int
    let relaysReached: Int
    let relaysTotal: Int
    /// "none", "reached" or "not_reached".
    let otherVault: String

    static let marker = "IMPORT_RESULT"

    /// The line anywhere in `text` (a log line keeps its timestamp and emoji
    /// in front). Unknown keys are ignored; a missing or unknown status is nil.
    static func parse(_ text: String) -> ImportResult? {
        guard let range = text.range(of: marker + " ") else { return nil }
        var fields: [String: String] = [:]
        for pair in text[range.upperBound...].split(separator: " ") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        guard let status = fields["status"].flatMap(Status.init(rawValue:)) else { return nil }
        let relays = (fields["relays"] ?? "").split(separator: "/").compactMap { Int($0) }
        return ImportResult(
            status: status,
            reasons: (fields["reason"] ?? "").split(separator: ",").map(String.init),
            owner: Int(fields["owner"] ?? "") ?? 0,
            tagged: Int(fields["tagged"] ?? "") ?? 0,
            relaysReached: relays.count == 2 ? relays[0] : 0,
            relaysTotal: relays.count == 2 ? relays[1] : 0,
            otherVault: fields["other_vault"] ?? "none")
    }

    /// StartRelayC(1) returned but no result line came back.
    static let noResult = ImportResult(status: .failed, reasons: ["no_result"], owner: 0, tagged: 0,
                                       relaysReached: 0, relaysTotal: 0, otherVault: "none")

    /// Cancelled before the Go side ran it (held or between retries).
    static let cancelledBeforeStart = ImportResult(status: .cancelled, reasons: ["cancelled"], owner: 0, tagged: 0,
                                                   relaysReached: 0, relaysTotal: 0, otherVault: "none")

    var isComplete: Bool { status == .complete }

    /// The Go side didn't run it because the last relay cycle hadn't let go
    /// yet: worth starting again shortly.
    var isRetryableStart: Bool {
        status == .failed && (reasons == ["already_running"] || reasons == ["still_draining"])
    }

    var otherVaultNotReached: Bool { otherVault == "not_reached" }

    // MARK: Words

    static let completeLine = "Import Complete!"
    static let cancelledLine = "Import cancelled"
    static let otherVaultNotReachedLine = "Your other vault was not reached; your notes came from your relays"

    /// What the screens say once it ended.
    var summary: String {
        switch status {
        case .complete:
            return Self.completeLine
        case .cancelled:
            return Self.cancelledLine
        case .partial:
            if reasons == ["other_vault_not_reached"] { return Self.otherVaultNotReachedLine }
            return "Imported \(owner.formatted()) notes, but some may be missing. Run the import again to fill the gaps."
        case .failed:
            switch reasons.first {
            case "no_seed_relay": return "Couldn't reach any relay. Check your connection, then try again."
            case "already_running", "still_draining": return "The vault was still busy. Try again in a moment."
            default: return "The import couldn't run. Try again."
            }
        }
    }
}
