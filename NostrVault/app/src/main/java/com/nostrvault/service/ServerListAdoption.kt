package com.nostrvault.service

import com.nostrvault.service.NostrService.Companion.isLoopbackRelay

/**
 * The owner's media server list (BUD-03 kind 10063) set in another app,
 * brought into this device's upload servers. Uploads go to
 * `HavenConfig.activeBlossomMirrors`, so a server only on the published list
 * was never uploaded to.
 *
 * Their list wins, in their order: BUD-03 clients try servers in order, so
 * the first one is their default. Servers only this device had (app
 * defaults, the setup suggestion) are dropped, so ours stay only when they
 * have none. A server this device published and later removed is not added
 * back (it is in [base] but not in [local]). Same newest-wins stamp as the DM
 * inbox list: a list no newer than the last change here, or than the last
 * one adopted, changes nothing.
 */
internal object ServerListAdoption {

    data class Result(val mirrors: List<String>, val added: List<String>, val updatedAt: Long)

    /**
     * Null when nothing changes. [local] is `blossomMirrors`, [updatedAt] when
     * it last changed, [published] the servers on the newest list and
     * [publishedAt] its created_at, [base] what this device last published,
     * [ownServers] the Mac relay's media address, which the app adds itself.
     * A published list with no usable server leaves [local] as it is.
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
        val localKeys = local.map(ListMerge::key).toSet()
        val removedHere = base.orEmpty().map(ListMerge::key).filter { it !in localKeys }
        val skip = (removedHere + ownServers.map(ListMerge::key)).toMutableSet()
        val theirs = published.map(String::trim).filter { url -> usable(url) && skip.add(ListMerge.key(url)) }
        if (theirs.isEmpty()) return null
        val added = theirs.filter { ListMerge.key(it) !in localKeys }
        return Result(theirs, added, publishedAt)
    }

    /** True when [mirrors] has servers and none is https: Media servers warns (Tron #1451). */
    fun allPlainHttp(mirrors: List<String>): Boolean =
        mirrors.isNotEmpty() && mirrors.none { it.trim().startsWith("https://", ignoreCase = true) }

    private fun usable(url: String): Boolean =
        (url.startsWith("https://", ignoreCase = true) || url.startsWith("http://", ignoreCase = true)) &&
            !url.contains(' ') && !isLoopbackRelay(url)
}
