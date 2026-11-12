import Foundation

/// Who is new in your web, for Your space's WoT mini panel: the Swift twin of
/// the web's `newInWeb` (web-vault/src/desktop/space/wot-mini.js). People
/// your follows have come to vouch for since this device last looked; someone
/// stays new for a week while still vouched for. A first look only notes
/// everyone. Known people are never forgotten, so someone a missing list
/// hides for a while doesn't come back as new.
struct WotNewcomers: Equatable, Codable {
    static let faces = 6
    static let newFor: Int64 = 7 * 86400
    static let kept = 40

    /// First 8 hex characters of everyone seen in the web.
    var known: Set<String> = []
    /// Newcomers and when this device first saw them, newest first.
    var fresh: [Fresh] = []

    struct Fresh: Equatable, Codable {
        let pubkey: String
        let at: Int64
    }

    private static func short(_ pk: String) -> String { String(pk.prefix(8)) }

    /// `vouched`: the web's extended layer, most linked first. `kept` nil on a first look.
    /// Anyone in `muted` (the mute list, kind 10000, public and private) is never
    /// offered and never newly noted, and drops out of new once muted: the web's
    /// `newInWeb` does the same.
    static func update(vouched allVouched: [String], kept: WotNewcomers?, now: Int64, muted: Set<String> = []) -> WotNewcomers {
        let vouched = muted.isEmpty ? allVouched : allVouched.filter { !muted.contains($0) }
        guard var next = kept else {
            return WotNewcomers(known: Set(vouched.map(short)), fresh: [])
        }
        let still = Set(vouched)
        let stillFresh = next.fresh.filter { still.contains($0.pubkey) && now - $0.at < newFor }
        let had = Set(stillFresh.map(\.pubkey))
        let arrived = vouched.filter { !next.known.contains(short($0)) && !had.contains($0) }.map { Fresh(pubkey: $0, at: now) }
        next.known.formUnion(vouched.map(short))
        next.fresh = Array((arrived + stillFresh).prefix(Self.kept))
        return next
    }

    static func key(_ owner: String) -> String { "nv-wot-seen:\(owner)" }
}
