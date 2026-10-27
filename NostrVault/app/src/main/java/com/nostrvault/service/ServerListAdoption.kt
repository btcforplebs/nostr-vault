package com.nostrvault.service

import com.nostrvault.service.NostrService.Companion.isLoopbackRelay

/**
 * The owner's media server list (BUD-03 kind 10063) set in another app,
 * brought into this device's upload servers. Uploads go to
 * `HavenConfig.activeBlossomMirrors`, so a server only on the published list
 * was never uploaded to.
 *
 * Adds only. A server this device has stays, and a server this device
 * published and later removed is not added back (it is in [base] but not in
 * [local]). Same newest-wins stamp as the DM inbox list: a list no newer
 * than the last change here, or than the last one adopted, changes nothing.
 */
internal object ServerListAdoption {

    data class Result(val mirrors: List<String>, val added: List<String>, val updatedAt: Long)

    /**
     * Null when nothing changes. [local] is `blossomMirrors`, [updatedAt] when
     * it last changed, [published] the servers on the newest list and
     * [publishedAt] its created_at, [base] what this device last published,
     * [ownServers] the Mac relay's media address, which the app adds itself.
     */
    fun adopt(
        local: List<String>,
        updatedAt: Long?,
        published: List<String>,
        publishedAt: Long,
        base: List<String>?,
        ownServers: List<String> = emptyList(),
    ): Result? {
        if (updatedAt != null && publishedAt <= updatedAt) return null
        val skip = (local + base.orEmpty() + ownServers).map(ListMerge::key).toMutableSet()
        val added = published.map(String::trim).filter { url ->
            usable(url) && skip.add(ListMerge.key(url))
        }
        return Result(local + added, added, publishedAt)
    }

    private fun usable(url: String): Boolean =
        (url.startsWith("https://", ignoreCase = true) || url.startsWith("http://", ignoreCase = true)) &&
            !url.contains(' ') && !isLoopbackRelay(url)
}
