package com.nostrvault.service

import com.nostrvault.data.model.AccountWeb
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedReach
import com.nostrvault.data.model.WebGate
import java.io.File

/**
 * The feed's side of [WebGate]: the hop past the open account's web, and how
 * far the current feed reaches. iOS `FeedService+WebGate.swift`.
 */

/**
 * One hop past the open account's web ([WebGate.loose]), from the same saved
 * graph and links file as [accountWeb]. Fails closed: no follow list yet, or
 * a links file it cannot read, is nobody (depth 3) or the pooled rest (other
 * depths, as iOS).
 */
internal fun FeedService.accountLoose(saved: Set<String>, web: Set<String>, links: File, depth: Int?, minFollowers: Int): Set<String> =
    WebGate.cleanLoose(accountLooseRaw(saved, links, depth, minFollowers), web)

/** [accountLoose] before it is lowercased and has [accountWeb] taken out. */
private fun FeedService.accountLooseRaw(saved: Set<String>, links: File, depth: Int?, minFollowers: Int): Set<String> {
    val follows = followedPubkeySet()
    val counts = if (depth == 3 && links.exists()) {
        runCatching { links.bufferedReader().use { AccountWeb.vouchCounts(it, follows) } }.getOrNull()
    } else null
    if (depth == 3 && counts == null) return emptySet()
    return WebGate.loose(saved, follows, counts, depth, deviceAccountHexes(), minFollowers)
}

/** How far [mode] reaches: Everyone for a Global list with the shield off, else its Reach setting. */
internal fun FeedService.feedReach(mode: FeedMode, globalLike: Boolean): WebGate.Reach {
    val config = configStore.config.value
    if (globalLike && config.globalShowsEveryone) return WebGate.Reach.EVERYONE
    return FeedReach.reach(mode, config.feedReach)
}

/** The current feed's reach; a feed not gated on Android yet ([FeedReach.gatedModes]) keeps to its web. */
internal fun FeedService.currentFeedReach(): WebGate.Reach {
    val mode = _feedMode.value
    if (mode !in FeedReach.gatedModes) return WebGate.Reach.WEB
    return feedReach(mode, isGlobalLikeMode())
}

/** Saves [reach] for [mode] and re-judges the notes on screen. */
fun FeedService.setFeedReach(mode: FeedMode, reach: WebGate.Reach) {
    configStore.update { it.copy(feedReach = FeedReach.setting(reach, mode, it.feedReach)) }
    recomputeFilteredNotes()
}

