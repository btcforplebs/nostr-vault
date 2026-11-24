package com.nostrvault.service

import com.nostrvault.data.model.DistantPostAuthors
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.remote.WebSocketClient

/**
 * Discover's second filter, on the request to this device's own feed store
 * only: the distant connections' posts a desktop Vault handed over the mesh
 * ([DistantPostAuthors]). External relays are not asked for them. Null for
 * every other feed and relay. iOS `FeedService+DistantPosts.swift`.
 */
internal fun FeedService.distantPostsFilter(filter: String, relayUrl: String): String? {
    if (_feedMode.value != FeedMode.DISCOVERY || relayUrl != configStore.config.value.localRelayURL("feed")) return null
    return DistantPostAuthors.localFilter(filter, discoveryReach.localDistantAuthors)
}

/**
 * Sends Discover's request to this device's own feed store again, so it
 * carries the current distant list, older notes included. Same subscription
 * id, so the store replaces the old one. A client still connecting reads the
 * list when it connects; other feeds never carry the filter. The owner's
 * deletion REQ stays as it was: asking it again replays every kind 5.
 */
internal fun FeedService.resendDistantPostsRequest() {
    if (_feedMode.value != FeedMode.DISCOVERY) return
    val local = configStore.config.value.localRelayURL("feed") ?: return
    if (feedClients[local]?.connectionState?.value != WebSocketClient.ConnectionState.CONNECTED) return
    sendPrimaryFeedSubscription(local, primaryFeedSubId(), resume = false, withDeletes = false)
}
