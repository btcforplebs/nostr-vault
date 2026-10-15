import Foundation

/// Zaps on the WOT globe: a lightning bolt from the zapper to the person
/// zapped, a quick jagged flash with a short afterglow, unlike a note's star.
extension GlobeArcs {
    /// A zap receipt (NIP-57).
    static let zapKind = 9735
    /// The zap request the receipt carries in its `description` tag.
    static let zapRequestKind = 9734
    /// The bolt strikes across in this long,
    static let boltStrike: TimeInterval = 0.12
    /// stays at full flash this long,
    static let boltFlash: TimeInterval = 0.35
    /// and its afterglow fades over this long.
    static let boltGlow: TimeInterval = 1.4
    static var boltLife: TimeInterval { boltStrike + boltFlash + boltGlow }

    /// A zap receipt as a bolt from the zapper to the person zapped. The
    /// receipt's own pubkey is the LNURL server, so the zapper is the zap
    /// request's (`description`, kind 9734) pubkey. Receipts can be forged:
    /// one whose request doesn't parse, isn't a 9734, names someone other
    /// than the receipt's `p`, or fails `verify` (its id and signature,
    /// checked on the request's own JSON) draws nothing. Without the check
    /// anyone could draw a bolt from anyone, or pass a stranger off as a
    /// follow past Global's trust filter. No amount is read.
    static func zap(_ event: [String: Any], now: Date = Date(), verify: (String) -> Bool) -> Arrival? {
        guard event["kind"] as? Int == zapKind, let id = event["id"] as? String, isKey(id) else { return nil }
        if let created = event["created_at"] as? Double,
           now.timeIntervalSince1970 - created > maxAge { return nil }
        let tags = event["tags"] as? [[String]] ?? []
        func values(_ name: String, in tags: [[String]]) -> [String] {
            tags.filter { $0.count >= 2 && $0[0] == name }.map { $0[1].lowercased() }
        }
        guard values("p", in: tags).count == 1, let recipient = values("p", in: tags).first, isKey(recipient),
              let description = tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
              let data = description.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              request["kind"] as? Int == zapRequestKind,
              let zapper = request["pubkey"] as? String, isKey(zapper), zapper == zapper.lowercased(),
              let requestTags = request["tags"] as? [[String]],
              values("p", in: requestTags) == [recipient],
              zapper != recipient,
              // Last, as the one costly check: the request is the zapper's
              // own. It is checked as Swift read it, rebuilt from the fields
              // above, never as the raw text: JSON with a key twice reads
              // first-wins here and last-wins in the verifier, so the raw
              // text could prove one zapper while Swift drew another.
              let signed = canonicalRequest(request), verify(signed) else { return nil }
        return Arrival(id: id, author: zapper, targets: [recipient], zap: true)
    }

    /// A zap request rebuilt from Swift's own reading of it, with exactly
    /// the NIP-01 fields, for the signature check. nil unless every field is
    /// there with its proper type: a 64-hex id, pubkey and created_at as an
    /// exact integer (so it renders `1799999990`, never `1.79e+09`), string
    /// tags and content, and a sig.
    static func canonicalRequest(_ request: [String: Any]) -> String? {
        guard let id = request["id"] as? String, isKey(id),
              let pubkey = request["pubkey"] as? String, isKey(pubkey),
              let created = request["created_at"] as? Int,
              let kind = request["kind"] as? Int,
              let tags = request["tags"] as? [[String]],
              let content = request["content"] as? String,
              let sig = request["sig"] as? String else { return nil }
        let event: [String: Any] = ["id": id, "pubkey": pubkey, "created_at": created, "kind": kind,
                                    "tags": tags, "content": content, "sig": sig]
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A bolt's moment: `head` how far it has struck across, then a full
    /// flash, then an afterglow fading out. Reduce Motion: there at once,
    /// one steady line that fades.
    static func boltStage(of line: Line, at now: TimeInterval, reduceMotion: Bool = false) -> Stage {
        let age = max(0, now - line.born)
        let head = reduceMotion ? 1 : min(1, age / boltStrike)
        let lit = boltStrike + boltFlash
        var alpha = age <= lit ? 1 : 1 - min(1, (age - lit) / boltGlow)
        alpha *= alpha
        if let retired = line.retired {
            alpha = min(alpha, 1 - min(1, max(0, now - retired) / retireFade))
        }
        let landing = reduceMotion ? 0 : max(0, min(1, (age - boltStrike) / boltFlash))
        return Stage(head: head, trail: alpha, alpha: max(0, alpha), landing: landing)
    }

    /// True while the bolt still flickers: during its flash, not its afterglow.
    static func boltFlickers(_ line: Line, at now: TimeInterval) -> Bool {
        now - line.born < boltStrike + boltFlash
    }
}

/// The bolt's jagged shape: sideways offsets along it, as fractions of its
/// length, and one short fork. Pinned at both ends, widest in the middle,
/// and the same for the same zap and flicker frame, so a frame drawn twice
/// draws the same bolt.
enum GlobeBolt {
    /// Points along a bolt.
    static let segments = 14
    /// New shapes a second while it flashes.
    static let flickerRate = 16.0
    /// Widest sideways reach, as a fraction of its length.
    static let reach = 0.07

    /// A stable seed from a zap's id (FNV-1a).
    static func seed(_ id: String) -> UInt64 {
        id.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
    }

    /// The flicker frame at a time; one frame for good once it stops.
    static func frame(at age: TimeInterval, flickers: Bool) -> Int {
        flickers ? Int(age * flickerRate) : -1
    }

    private static func random(_ state: inout UInt64) -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53) * 2 - 1
    }

    /// `segments + 1` offsets, 0 at both ends. Reduce Motion: all 0, a plain line.
    static func offsets(seed: UInt64, frame: Int, reduceMotion: Bool) -> [Double] {
        guard !reduceMotion else { return Array(repeating: 0, count: segments + 1) }
        var state = seed ^ UInt64(bitPattern: Int64(frame)) &* 0xD6E8_FEB8_6659_FD93
        return (0...segments).map { i in
            guard i > 0, i < segments else { return 0 }
            let t = Double(i) / Double(segments)
            return random(&state) * reach * sin(t * .pi)
        }
    }

    /// The fork: which point it leaves from, its turn off the bolt (radians)
    /// and its length as a fraction of the bolt's.
    static func fork(seed: UInt64) -> (from: Int, turn: Double, length: Double) {
        var state = seed &* 0x2545_F491_4F6C_DD1D
        let from = segments / 3 + Int((random(&state) + 1) / 2 * Double(segments / 3))
        return (from, (random(&state) >= 0 ? 1 : -1) * (0.45 + 0.25 * abs(random(&state))), 0.16 + 0.08 * abs(random(&state)))
    }
}
