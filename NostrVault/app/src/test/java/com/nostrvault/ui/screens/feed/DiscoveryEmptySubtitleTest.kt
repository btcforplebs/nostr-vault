package com.nostrvault.ui.screens.feed

import org.junit.Assert.assertEquals
import org.junit.Test

class DiscoveryEmptySubtitleTest {

    @Test
    fun newAccountWithANetworkButNoTrustGraphIsBuildingNotFailing() {
        // Sweep 11-01: 10 of 11 follow lists, 4,076 people, graph not built yet.
        assertEquals(
            "Building your Web of Trust… Posts appear once it's ready",
            DiscoveryEmptySubtitle.of(followsSomeone = true, trustGraphReady = false, networkFound = true),
        )
    }

    @Test
    fun noFollowListsCameBackOnlyWhenTheNetworkIsEmpty() {
        assertEquals(
            "No follow lists came back from your relays — try refreshing",
            DiscoveryEmptySubtitle.of(followsSomeone = true, trustGraphReady = true, networkFound = false),
        )
        assertEquals(
            "No follow lists came back from your relays — try refreshing",
            DiscoveryEmptySubtitle.of(followsSomeone = true, trustGraphReady = false, networkFound = false),
        )
    }

    @Test
    fun followingNobodyAsksForFollows() {
        assertEquals(
            "Follow more people on Nostr to build your extended network",
            DiscoveryEmptySubtitle.of(followsSomeone = false, trustGraphReady = false, networkFound = false),
        )
    }

    @Test
    fun graphReadyAndNetworkFoundButNoPostsYet() {
        assertEquals(
            "No posts from your extended network yet — try refreshing",
            DiscoveryEmptySubtitle.of(followsSomeone = true, trustGraphReady = true, networkFound = true),
        )
    }
}
