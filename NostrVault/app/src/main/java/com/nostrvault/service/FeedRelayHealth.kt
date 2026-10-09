package com.nostrvault.service

/** Each feed relay's own socket state, keyed one way however its URL was typed (iOS #281). */
object FeedRelayHealth {
    /** Key a relay URL the same way however it was typed (case, trailing slash). */
    fun key(url: String): String = url.trim().lowercase().trimEnd('/')
}
