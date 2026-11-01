package com.nostrvault.ui.screens.feed

/**
 * Why Discover is empty once its network has been tallied. Discover keeps
 * only authors in the relay's trust graph, like Global, so a new account
 * whose graph isn't built yet sees nothing even with thousands of people in
 * its network: that is "building", not the relays failing (sweep 11-01).
 */
internal object DiscoveryEmptySubtitle {

    fun of(followsSomeone: Boolean, trustGraphReady: Boolean, networkFound: Boolean): String = when {
        !followsSomeone -> "Follow more people on Nostr to build your extended network"
        networkFound && !trustGraphReady -> "Building your Web of Trust… Posts appear once it's ready"
        !networkFound -> "No follow lists came back from your relays — try refreshing"
        else -> "No posts from your extended network yet — try refreshing"
    }
}
