package com.nostrvault.fips

import android.util.Log
import android.util.LruCache
import coil.request.ImageRequest

/**
 * Where a blob can be read over the FIPS mesh (NIP-F1).
 *
 * A vault on the mesh lists `fipsmesh://<npub>/` in its owner's kind 10063.
 * A read is routed only to the author of the note being drawn, passed in
 * with the image request ([meshAuthor]); never to whoever first mentioned a
 * blob, or anyone could post someone else's URL and pull readers to their
 * node. Only authors the owner follows are dialled ([mayDial]). Author ->
 * mesh npub comes from their 10063 ([serverLists]).
 */
object FipsMediaRouter {
    private const val TAG = "FipsMesh"

    const val SCHEME = "fipsmesh://"

    /** Author hex pubkey -> their 10063 server list. Wired by NostrService. */
    @Volatile
    var serverLists: () -> Map<String, List<String>> = { emptyMap() }

    /**
     * Who the owner follows (hex). The mesh dials only these: dialling a
     * vault shows it the reader's address, so a stranger must not be able to
     * log everyone who scrolls past their note. Wired by FeedService.
     */
    @Volatile
    var follows: Set<String> = emptySet()

    /** Whether a read of [author]'s media may go over the mesh. */
    fun mayDial(author: String): Boolean = author in follows

    /** Ask relays for an author's 10063. Wired by NostrService. */
    @Volatile
    var requestServerList: (String) -> Unit = {}

    private val requested = LruCache<String, Long>(1024)

    /** Vaults that sent wrong or oversized bytes: not asked again this session. */
    private val distrusted = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    private class Ingress(val base: String?, val at: Long)
    private val ingress = LruCache<String, Ingress>(32)

    /** How long a failed ingress is not retried, so a dead vault costs one wait. */
    private const val INGRESS_RETRY_MS = 30_000L
    /** How often a missing 10063 is asked for again. */
    private const val REQUEST_RETRY_MS = 5 * 60_000L

    private val meshEntryRegex = Regex("""fipsmesh://(npub1[02-9ac-hj-np-z]{58})/""")
    private val meshHostRegex = Regex("""(npub1[02-9ac-hj-np-z]{58})\.fips""")
    private val shaRegex = Regex("""(?:^|/)([0-9a-f]{64})(?:\.[A-Za-z0-9]{1,8})?$""")

    /** The sha256 a Blossom-style URL names, if it names one. */
    fun sha256In(url: String): String? {
        val path = url.substringBefore('#').substringBefore('?')
        return shaRegex.find(path.lowercase())?.groupValues?.get(1)
    }

    /**
     * The mesh npub [author] lists, or null. A missing list is fetched in
     * the background, so a later read of the same author can use it.
     */
    fun meshNpubFor(author: String): String? {
        val list = serverLists()[author]
        if (list == null) {
            val now = System.currentTimeMillis()
            val last = requested.get(author)
            if (last == null || now - last > REQUEST_RETRY_MS) {
                requested.put(author, now)
                requestServerList(author)
            }
            return null
        }
        return list.firstNotNullOfOrNull { meshNpubIn(it) }
    }

    /**
     * The vault a mesh-only URL (`http://<npub>.fips/<sha>`) names, or null.
     * That host is the one the author picked for this blob, so it wins over
     * whichever vault comes first in their 10063.
     */
    fun meshNpubInHost(host: String): String? =
        meshHostRegex.matchEntire(host.lowercase())?.groupValues?.get(1)

    /** `fipsmesh://<npub>/` exactly, or null: no port, user info, query or other path. */
    fun meshNpubIn(entry: String): String? =
        meshEntryRegex.matchEntire(entry)?.groupValues?.get(1)

    /**
     * The loopback base for [npub]'s vault, or null when the mesh is off or
     * the vault can't be reached. Blocks up to 10 s the first time: never on
     * the main thread. A failure is remembered for [INGRESS_RETRY_MS].
     */
    fun ingressBase(npub: String): String? {
        if (npub in distrusted) return null
        val now = System.currentTimeMillis()
        ingress.get(npub)?.let { cached ->
            if (cached.base != null) return cached.base
            if (now - cached.at < INGRESS_RETRY_MS) return null
        }
        val result = FipsBridge.ingress(npub)
        if (result.url == null) Log.w(TAG, "ingress ${npub.take(12)}: ${result.error}")
        ingress.put(npub, Ingress(result.url, now))
        return result.url
    }

    /**
     * Stop asking [npub] for the rest of the session. Wrong bytes are not a
     * passing fault, and each try can cost up to the read cap in data.
     */
    fun distrust(npub: String) {
        distrusted.add(npub)
        ingress.remove(npub)
    }

    /** Drop a base that stopped answering (node restarted, vault evicted). */
    fun forget(npub: String) {
        ingress.remove(npub)
    }
}

/** The author of the note an image request draws: the only vault NIP-F1 lets it read from. */
data class MeshAuthor(val pubkey: String)

/** Let this image be read from [pubkey]'s vault on the FIPS mesh. Null leaves it off the mesh. */
fun ImageRequest.Builder.meshAuthor(pubkey: String?): ImageRequest.Builder =
    if (pubkey.isNullOrEmpty()) this else tag(MeshAuthor::class.java, MeshAuthor(pubkey))
