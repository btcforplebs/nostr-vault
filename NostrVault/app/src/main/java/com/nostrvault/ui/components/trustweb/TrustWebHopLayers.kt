package com.nostrvault.ui.components

import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustMapOuter

/**
 * The layer picker's Hop 3, 4 and 5 ([TrustMap.Layer.hop]): always in the
 * list, greyed out until a desktop Vault's ranking with that ring is on this
 * device ([TrustMapOuter.unlocks]), as the reason to run one. A greyed hop
 * says so in one line; an unlocked one zooms the globe out to its ring
 * ([com.nostrvault.data.model.GlobeRingZoom]). iOS `TrustWebView+HopLayers.swift`.
 */
internal object TrustWebHopLayers {
    /** The hop layers greyed out: no ranked ring for them here yet. */
    fun locked(outer: TrustMapOuter): Set<TrustMap.Layer> =
        TrustMap.Layer.entries.filterTo(HashSet()) { item -> item.hop?.let { !outer.unlocks(it) } ?: false }

    /** Layer counts with each unlocked hop's ring. */
    fun withHops(counts: Map<TrustMap.Layer, Int>, outer: TrustMapOuter): Map<TrustMap.Layer, Int> {
        val out = counts.toMutableMap()
        for (item in TrustMap.Layer.entries) {
            val hop = item.hop ?: continue
            if (outer.unlocks(hop)) outer.rings.firstOrNull { it.hop == hop }?.let { out[item] = it.count }
        }
        return out
    }

    /** The WOT tab's list for a hop: that ring's best, best first. Else the layer's people. */
    fun listed(layer: TrustMap.Layer, outer: TrustMapOuter, people: () -> TrustMap.LayerPeople): TrustMap.LayerPeople {
        val hop = layer.hop ?: return people()
        return TrustMap.LayerPeople(emptyList(), outer.rings.firstOrNull { it.hop == hop }?.top.orEmpty())
    }
}
