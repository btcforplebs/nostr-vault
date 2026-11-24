package com.nostrvault.data.model

/**
 * Settings › Feed › Reach: how far each feed reaches (Logen 2026-11-18). iOS
 * `FeedReach.swift`. "Your web" ([WebGate.Reach.WEB]) or "Your web + a few
 * one hop out" ([WebGate.Reach.WEB_AND_LOOSE], rationed by
 * [WebGate.capLoose]). Underrated reaches one hop out by default; every other
 * feed keeps to your web. Following and Catch Up are your follows by
 * definition and have no setting.
 *
 * The setting is a map from a feed's key to a reach's stored word, saved as
 * `HavenConfig.feedReach`. The keys are iOS's `FeedMode` raw values, so the
 * two apps read each other's saved words.
 */
object FeedReach {

    /** The feeds with a Reach setting, in Settings order, with their saved keys (iOS raw values). */
    val modes: List<FeedMode> = listOf(FeedMode.DISCOVERY, FeedMode.GLOBAL, FeedMode.POPULAR, FeedMode.UNDERRATED, FeedMode.MEDIA)

    /**
     * The feeds that go through [WebGate] on Android so far, and so get a
     * Reach row and have their reach applied. Popular, Media, Discovery and
     * Global are not gated here yet: their saved words are kept (iOS shares
     * them) but read as [WebGate.Reach.WEB] until they are (Tron, #2415).
     */
    val gatedModes: List<FeedMode> = listOf(FeedMode.UNDERRATED)

    fun key(mode: FeedMode): String = when (mode) {
        FeedMode.DISCOVERY -> "Discovery"
        else -> mode.displayName
    }

    fun defaultReach(mode: FeedMode): WebGate.Reach =
        if (mode == FeedMode.UNDERRATED) WebGate.Reach.WEB_AND_LOOSE else WebGate.Reach.WEB

    /** Anything missing, unknown or Everyone (never a setting) is the default. */
    fun reach(mode: FeedMode, settings: Map<String, String>): WebGate.Reach {
        if (mode !in modes) return WebGate.Reach.WEB
        val saved = WebGate.Reach.fromStored(settings[key(mode)])
        return if (saved != null && saved != WebGate.Reach.EVERYONE) saved else defaultReach(mode)
    }

    /** [settings] with [mode] set to [reach]; the default is stored as absent. */
    fun setting(reach: WebGate.Reach, mode: FeedMode, settings: Map<String, String>): Map<String, String> =
        if (reach == defaultReach(mode)) settings - key(mode) else settings + (key(mode) to reach.stored)

    fun label(reach: WebGate.Reach): String = when (reach) {
        WebGate.Reach.WEB -> "Your web"
        WebGate.Reach.WEB_AND_LOOSE -> "Your web + a few one hop out"
        WebGate.Reach.EVERYONE -> "Everyone"
    }
}
