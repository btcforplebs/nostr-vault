import Foundation

/// The `nostr:` references a note makes to other events, and the coordinate
/// string the app uses to name an addressable (NIP-33) event it has not
/// resolved yet.
///
/// The bech32 decoding itself lives in `Bech32`; everything here is pure string
/// and TLV work so it can be tested without a relay or a live app.
enum QuoteReference {
    /// Prefix marking an addressable-event coordinate rather than a 32-byte event id.
    static let coordinatePrefix = "naddr:"

    private static let referenceRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"nostr:(note1[a-z0-9]+|nevent1[a-z0-9]+|naddr1[a-z0-9]+)"#,
            options: .caseInsensitive
        )
    }()

    /// Every `nostr:note1…` / `nostr:nevent1…` / `nostr:naddr1…` identifier in
    /// `content`, in the order they appear, with repeats dropped.
    ///
    /// Repeats are dropped because the identifiers address rows in a list: the
    /// same reference twice is the same card twice, and SwiftUI's `ForEach`
    /// needs the ids it is given to be unique.
    static func identifiers(in content: String) -> [String] {
        guard let regex = referenceRegex else { return [] }
        let ns = content as NSString
        var seen = Set<String>()
        return regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
            .filter { seen.insert($0).inserted }
    }

    /// The event id carried by an `nevent` TLV payload — type 0, 32 bytes.
    static func eventID(fromNeventTLV payload: Data) -> String? {
        for entry in tlvEntries(payload) where entry.type == 0 && entry.value.count == 32 {
            return hex(entry.value)
        }
        return nil
    }

    /// The pubkey a profile mention names, from its decoded bech32 payload.
    /// `npub` is the 32 raw bytes; `nprofile` is TLV with the pubkey as type 0
    /// and relay hints after it. Hex-encoding an nprofile's whole payload —
    /// what the mention tap did — gives a 144-character "pubkey" that opens a
    /// blank stranger. Nil for anything that does not hold exactly 32 bytes.
    static func profilePubkey(hrp: String, payload: Data) -> String? {
        switch hrp.lowercased() {
        case "npub":
            return payload.count == 32 ? hex(payload) : nil
        case "nprofile":
            return tlvEntries(payload).first { $0.type == 0 && $0.value.count == 32 }.map { hex(Data($0.value)) }
        default:
            return nil
        }
    }

    /// The kind, author and `d` tag an `naddr` TLV payload names, or nil when it
    /// names no event we can trust.
    ///
    /// NIP-19 naddr TLV: type 0 = d-tag (UTF-8), 1 = relay, 2 = pubkey (32 bytes),
    /// 3 = kind (4 bytes, big endian). Kind and pubkey are both required — without
    /// them the reference names no event.
    ///
    /// The relay hint (type 1) is read by nobody on purpose. The naddr in a
    /// `nostr:` link or in someone else's note is attacker-controlled, and
    /// honouring its hint would let whoever wrote the link choose a host for the
    /// app to connect to. Lookups go to the user's configured relays instead.
    ///
    /// A type-0 value that is not valid UTF-8 fails the whole reference. It used
    /// to decode to nil and fall back to `""`, which is a *different, legal*
    /// coordinate — the author's empty-`d` event of the same kind — so a crafted
    /// naddr opened one event under the name of another. A zero-length type-0
    /// value is a real empty `d` tag and still resolves; Foundation decodes empty
    /// data to `""`, not nil, so the two cases stay apart.
    static func naddrParts(fromTLV payload: Data) -> (kind: Int, pubkey: String, dTag: String)? {
        var dTag = ""
        var pubkey: String?
        var kind: UInt32?

        for entry in tlvEntries(payload) {
            switch entry.type {
            case 0:
                guard let decoded = String(data: Data(entry.value), encoding: .utf8) else { return nil }
                dTag = decoded
            case 2 where entry.value.count == 32: pubkey = hex(entry.value)
            case 3 where entry.value.count == 4:
                kind = Data(entry.value).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            default: break
            }
        }

        guard let kind = kind, let pubkey = pubkey else { return nil }
        return (Int(kind), pubkey, dTag)
    }

    /// A `"naddr:<kind>:<pubkey>:<d-tag>"` coordinate from an `naddr` TLV payload.
    /// Same rules as `naddrParts(fromTLV:)`, which does the reading.
    static func coordinate(fromNaddrTLV payload: Data) -> String? {
        guard let parts = naddrParts(fromTLV: payload) else { return nil }
        return coordinate(kind: parts.kind, pubkey: parts.pubkey, dTag: parts.dTag)
    }

    /// Builds the coordinate string. One definition, so the parser below cannot drift from it.
    static func coordinate(kind: Int, pubkey: String, dTag: String) -> String {
        "\(coordinatePrefix)\(kind):\(pubkey):\(dTag)"
    }

    /// Splits a coordinate back into its parts. Returns nil for anything that is
    /// not a coordinate — including a plain 64-hex event id.
    static func parseCoordinate(_ coordinate: String) -> (kind: Int, pubkey: String, dTag: String)? {
        guard coordinate.hasPrefix(coordinatePrefix) else { return nil }
        // maxSplits 3 keeps a d-tag containing ":" intact.
        let parts = coordinate.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let kind = Int(parts[1]), !parts[2].isEmpty else { return nil }
        return (kind, parts[2], parts.count > 3 ? parts[3] : "")
    }

    /// Whether events answer one quote reference.
    ///
    /// One definition for both stores: the feed keeps `FeedNote`s and the relay
    /// tab keeps `NostrEvent`s, and they must not disagree about which event a
    /// reference points at. A plain id matches by id; a coordinate matches an
    /// addressable event by kind, author and `d` tag.
    ///
    /// It is a value rather than a free function because the callers scan a list:
    /// the coordinate is parsed once here instead of once per event examined.
    struct Matcher {
        private let identifier: String
        private let wanted: (kind: Int, pubkey: String, dTag: String)?

        init(identifier: String) {
            self.identifier = identifier
            self.wanted = QuoteReference.parseCoordinate(identifier)
        }

        func matches(id: String, kind: Int, pubkey: String, tags: [[String]]) -> Bool {
            guard let wanted = wanted else { return id == identifier }
            return kind == wanted.kind && pubkey == wanted.pubkey
                && tags.contains { $0.count >= 2 && $0[0] == "d" && $0[1] == wanted.dTag }
        }
    }

    static func matcher(for identifier: String) -> Matcher { Matcher(identifier: identifier) }

    /// Single-event convenience for callers that are not scanning.
    static func event(id: String, kind: Int, pubkey: String, tags: [[String]], matches identifier: String) -> Bool {
        matcher(for: identifier).matches(id: id, kind: kind, pubkey: pubkey, tags: tags)
    }

    // MARK: - TLV

    private struct TLVEntry {
        let type: UInt8
        let value: Data
    }

    /// Walks a NIP-19 TLV payload. A truncated entry ends the walk rather than
    /// being read past — a malformed reference should yield nothing, not garbage.
    private static func tlvEntries(_ payload: Data) -> [TLVEntry] {
        var entries: [TLVEntry] = []
        var rest = Data(payload)
        while rest.count >= 2 {
            let type = rest.removeFirst()
            let length = Int(rest.removeFirst())
            guard rest.count >= length else { break }
            entries.append(TLVEntry(type: type, value: Data(rest.prefix(length))))
            rest.removeFirst(length)
        }
        return entries
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
