package com.nostrvault.service

import com.nostrvault.data.model.DistantPostAuthors
import com.nostrvault.data.model.FeedMode

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
