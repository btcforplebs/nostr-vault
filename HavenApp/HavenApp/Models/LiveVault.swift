import Foundation

/// The rules for the iPad's "Your space" column (Live Vault), kept free of
/// views so tests can run them. A twin of web-vault's
/// `src/desktop/space/live-vault.js`: the column draws the Vault list's lines
/// beside whatever is open and keeps still while you read it. Lines that
/// arrive after it was drawn go on top by themselves, and a line that
/// changes in place (a like that gained a face) keeps its slot.
enum LiveVault {
    /// Rows the column draws at most.
    static let maxRows = 30
    /// Faces at the top of the column.
    static let topFaces = 5

    /// What the column shows: taken when it is first drawn, then moved on
    /// by `place` as lines come in.
    struct Snapshot: Equatable {
        /// The first `maxRows` lines' ids, newest first.
        var ids: [String]
        /// The newest moment among them (`now` when there are none).
        var top: Int64
    }

    static func snapshot(_ lines: [VaultActivity], now: Int64 = Int64(Date().timeIntervalSince1970)) -> Snapshot {
        Snapshot(ids: lines.prefix(maxRows).map(\.id), top: lines.first?.createdAt ?? now)
    }

    /// `lines` (newest first) against the snapshot on screen.
    /// `rows`: the snapshot's lines in the order they were drawn, each in its
    /// latest form (a line gone from `lines` drops out), then lines older than
    /// its newest that came in late, below them. Nothing already drawn moves.
    /// `held`: lines newer than the snapshot, not drawn yet.
    static func split(_ lines: [VaultActivity], _ shot: Snapshot) -> (rows: [VaultActivity], held: [VaultActivity]) {
        let byId = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let on = Set(shot.ids)
        let rows = shot.ids.compactMap { byId[$0] }
        let rest = lines.filter { !on.contains($0.id) }
        let held = rest.filter { $0.createdAt > shot.top }
        let late = rest.filter { $0.createdAt <= shot.top }
        return (Array((rows + late).prefix(max(maxRows, rows.count))), held)
    }

    /// Who to show on top: the people behind `lines`, newest first, each
    /// once, at most `n`, and how many more there are.
    static func faces(_ lines: [VaultActivity], n: Int = topFaces) -> (faces: [String], more: Int) {
        var seen = Set<String>()
        var all: [String] = []
        for line in lines { for pk in line.actors where seen.insert(pk).inserted { all.append(pk) } }
        return (Array(all.prefix(n)), max(0, all.count - n))
    }

    /// The snapshot after `lines` came in: lines newer than it go on top,
    /// newest first; every line already drawn (late older ones included)
    /// keeps its order below them. No snapshot yet takes a fresh one.
    static func place(_ lines: [VaultActivity], _ shot: Snapshot?) -> Snapshot {
        guard let shot else { return snapshot(lines) }
        let (rows, held) = split(lines, shot)
        return Snapshot(ids: (held + rows).prefix(maxRows).map(\.id),
                        top: max(shot.top, held.first?.createdAt ?? shot.top))
    }

    /// Where the folded/open choice is kept, per account.
    static func foldedKey(_ hex: String) -> String { "nv-space-folded:\(hex.lowercased())" }
}
