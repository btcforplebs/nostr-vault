package com.nostrvault.fips

import android.util.Log
import android.util.LruCache

/**
 * Where a blob can be read over the FIPS mesh.
 *
 * A vault on the mesh lists `fipsmesh://<npub>/` in its owner's kind 10063.
 * Notes name their media by a normal URL whose path carries the blob's
 * sha256, so reading one over the mesh takes two lookups: blob -> author
 * (recorded as notes arrive, [noteMedia]) and author -> mesh npub (their
 * 10063, [serverLists]). The blob is content-addressed, so the mesh copy is
 * the same bytes as the URL's.
 */
object FipsMediaRouter {
    private const val TAG = "FipsMesh"

    const val SCHEME = "fipsmesh://"

    /** Author hex pubkey -> their 10063 server list. Wired by NostrService. */
    @Volatile
    var serverLists: () -> Map<String, List<String>> = { emptyMap() }

    /** Ask relays for an author's 10063. Wired by NostrService. */
    @Volatile
    var requestServerList: (String) -> Unit = {}

    private val authorBySha = LruCache<String, String>(8192)
    private val requested = LruCache<String, Long>(1024)

    private class Ingress(val base: String?, val at: Long)
    private val ingress = LruCache<String, Ingress>(32)

    /** How long a failed ingress is not retried, so a dead vault costs one wait. */
    private const val INGRESS_RETRY_MS = 30_000L
    /** How often a missing 10063 is asked for again. */
    private const val REQUEST_RETRY_MS = 5 * 60_000L

    private val urlRegex = Regex("""https?://[^\s<>"']+""")
    private val shaRegex = Regex("""(?:^|/)([0-9a-f]{64})(?:\.[A-Za-z0-9]{1,8})?$""")

    /** The sha256 a Blossom-style URL names, if it names one. */
    fun sha256In(url: String): String? {
        val path = url.substringBefore('#').substringBefore('?')
        return shaRegex.find(path.lowercase())?.groupValues?.get(1)
    }

    /** Remember who posted each blob in a note, so a read knows whose vault to ask. */
    fun noteMedia(pubkey: String, content: String, tags: List<List<String>>) {
        if (pubkey.isEmpty()) return
        for (m in urlRegex.findAll(content)) record(m.value, pubkey)
        for (tag in tags) {
            if (tag.firstOrNull() != "imeta") continue
            for (part in tag.drop(1)) {
                if (part.startsWith("url ")) record(part.removePrefix("url "), pubkey)
            }
        }
    }

    private fun record(url: String, pubkey: String) {
        val sha = sha256In(url) ?: return
        if (authorBySha.get(sha) == null) authorBySha.put(sha, pubkey)
    }

    fun authorOf(sha: String): String? = authorBySha.get(sha)

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
        return list.firstNotNullOfOrNull { s ->
            if (!s.startsWith(SCHEME)) return@firstNotNullOfOrNull null
            s.removePrefix(SCHEME).trimEnd('/').takeIf { it.startsWith("npub1") }
        }
    }

    /**
     * The loopback base for [npub]'s vault, or null when the mesh is off or
     * the vault can't be reached. Blocks up to 10 s the first time: never on
     * the main thread. A failure is remembered for [INGRESS_RETRY_MS].
     */
    fun ingressBase(npub: String): String? {
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

    /** Drop a base that stopped answering (node restarted, vault evicted). */
    fun forget(npub: String) {
        ingress.remove(npub)
    }
}
