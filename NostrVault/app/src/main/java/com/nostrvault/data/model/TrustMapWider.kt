package com.nostrvault.data.model

import kotlin.math.roundToInt

/**
 * Someone else's globe: their own web past their follows, mapped from their
 * follows' follow lists, and the layer picker still lighting your part of it
 * (Logen, 10/15). iOS `TrustMapHaze.swift`.
 */
object TrustMapWider {
    /**
     * Whose follow lists are fetched to map someone else's wider web: a
     * spread of their follows, by key, so a big list still loads in seconds.
     */
    const val SAMPLE_CAP = 120

    fun sample(ring: List<String>): List<String> = TrustMap.haze(ring.toSet(), cap = SAMPLE_CAP)

    /** Everyone their follows follow, and how many of the lists name each person. */
    data class WiderWeb(val graph: Set<String>, val vouches: Map<String, Int>)

    /**
     * Someone else's web past their follows, from their follows' own lists:
     * everyone those follow, and how many of the lists name each person (their
     * vouches, as the relay counts yours). Only lists signed by someone in
     * [ring] count, the newest per signer.
     */
    fun web(center: String, ring: List<String>, lists: List<ContactList>): WiderWeb {
        val members = ring.toSet()
        val vouches = HashMap<String, Int>()
        for (signer in lists.asSequence().map { it.pubkey }.filter { it in members }.distinct()) {
            for (key in TrustMap.follows(signer, lists).orEmpty()) {
                if (key != center) vouches[key] = (vouches[key] ?: 0) + 1
            }
        }
        return WiderWeb(vouches.keys.toSet(), vouches)
    }

    /** The globe's outer shells for one web: the haze sample, who in it is Close, and each layer's face candidates. */
    data class HazeLayout(
        val shell: List<String> = emptyList(),
        val close: Set<String> = emptySet(),
        val layerFaces: Map<TrustMap.Layer, List<String>> = emptyMap(),
    )

    /**
     * Lays out the shells past [inner] (the core, their follows, you and the
     * author) for a web whose core is [me]. [faceScale] is how many more faces
     * the globe shows than [TrustMap]'s counts. iOS `TrustMap.hazeLayout`.
     */
    fun hazeLayout(
        graph: Set<String>,
        inner: Set<String>,
        vouches: Map<String, Int>?,
        me: String,
        follows: Set<String>,
        faceScale: Double,
        cap: Int = TrustMap.HAZE_CAP,
    ): HazeLayout {
        val shell = TrustMap.haze(graph - inner, cap)
        val layerFaces = listOf(TrustMap.Layer.EVERYONE, TrustMap.Layer.CLOSE, TrustMap.Layer.FURTHER_OUT).associateWith {
            TrustMap.layerFaceCandidates(it, me, follows, graph, vouches,
                (TrustMap.faceCandidateCount(it) * faceScale).roundToInt())
        }
        // Close is who someone is, by their vouches, not whether the haze
        // sample happened to take them.
        val close = TrustMap.closeByVouches(shell + layerFaces.values.flatten(), vouches)
        return HazeLayout(shell, close, layerFaces)
    }

    /**
     * The layer picker's people as a lit set, for a globe that isn't yours:
     * it still lights your follows, your Vouched and your Further out, so you
     * can see who in their web is close to you. Null for Everyone.
     */
    fun layerLit(
        layer: TrustMap.Layer,
        me: String,
        follows: Set<String>,
        web: Set<String>,
        vouches: Map<String, Int>?,
    ): Set<String>? = when (layer) {
        TrustMap.Layer.EVERYONE -> null
        TrustMap.Layer.FOLLOWING -> follows - me
        TrustMap.Layer.CLOSE, TrustMap.Layer.FURTHER_OUT ->
            TrustMap.layerPeople(layer, me, follows, web, vouches).web.toSet()
    }

    /** Who someone else's globe leaves lit: the filters and the layer, both still about you. */
    fun globeLit(filterLit: Set<String>?, layerLit: Set<String>?): Set<String>? {
        if (layerLit == null) return filterLit
        return filterLit?.intersect(layerLit) ?: layerLit
    }
}
