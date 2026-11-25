import SwiftUI

/// The layer picker's Hop 3, 4 and 5 (`TrustMap.Layer.hop`): always in the
/// list, greyed out until a desktop Vault's ranking with that ring is on
/// this device (`TrustMapOuter.unlocks`), as the reason to run one. A
/// greyed hop says so in one line; an unlocked one zooms the globe out to
/// its ring (`GlobeRingZoom`). Android twin: `TrustWebHopLayers.kt`.
extension TrustWebView {
    /// The hop layer is greyed out: no ranked ring for it here yet.
    func isLocked(_ item: TrustMap.Layer) -> Bool {
        guard let hop = item.hop else { return false }
        return !outerWatch.outer.unlocks(hop: hop)
    }

    /// Picks a layer, or says what unlocks a greyed hop.
    func pickLayer(_ item: TrustMap.Layer) {
        guard !isLocked(item) else {
            filterNote.show(FilterNote(icon: "lock.fill", text: TrustMapOuter.lockedLine))
            return
        }
        layer = item
    }

    /// Layer counts with each unlocked hop's ring: everyone its sphere
    /// draws (top plus haze). Without a haze the ring is only its top 300,
    /// a cap rather than a count, so it shows no number (Logen 2026-11-25).
    func countsWithHops(_ counts: [TrustMap.Layer: Int]) -> [TrustMap.Layer: Int] {
        var out = counts
        for item in TrustMap.Layer.allCases {
            guard let hop = item.hop, !isLocked(item) else { continue }
            out[item] = outerWatch.outer.rings.first { $0.hop == hop }.flatMap(TrustMapOuter.shownCount)
        }
        return out
    }

    /// A ranking that goes away (a new account, an unpaired Vault) takes a
    /// picked hop back to Everyone.
    func dropLockedLayer() {
        if isLocked(layer) { layer = .everyone }
    }

    /// A picked hop's sphere shows faces only for people whose picture is
    /// in (`GlobeHopSphere`): ask for its best people's profiles.
    func fetchSphereProfiles() {
        guard isWOTTab, let hop = layer.hop, let ring = outerWatch.outer.rings.first(where: { $0.hop == hop }) else { return }
        nostrService.fetchMissingProfiles(for: GlobeHopSphere.pictureKeys(ring))
    }

    /// Whether `key`'s picture is known, so the sphere draws their face
    /// rather than a lettered stand-in.
    func hasPicture(_ key: String) -> Bool {
        nostrService.profiles[key]?.pictureURL != nil
    }
}
