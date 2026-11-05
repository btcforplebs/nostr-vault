package com.nostrvault.service

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.net.URI

/**
 * Media import's second half (iOS `MirrorService.runMirror` step 2,
 * `BlossomService.mirrorFromNoteMedia`): the media links in your own notes
 * that point at outside servers, so a file you posted from another app before
 * this vault existed is copied in too. Pure, so the choice is testable.
 */
internal object NoteMediaScan {

    /**
     * Notes asked for per local relay page. The store may answer with fewer (the relay caps a plain query at 250),
     * so a short page is not the end: only a page with nothing new is ([collect]).
     */
    const val PAGE = 1_500

    /** Pages at most, so a huge history cannot keep the import scanning forever (400 x 250 = 100,000 notes). */
    const val MAX_PAGES = 400

    private val LOCAL_HOSTS = setOf("localhost", "127.0.0.1", "0.0.0.0")

    /**
     * The links to copy in, in first-seen order: each once, outside servers
     * only, and not a hash-named file this vault already holds.
     */
    fun urlsToImport(urls: List<String>, isStoredLocally: (String) -> Boolean): List<String> {
        val seen = LinkedHashSet<String>()
        for (url in urls) {
            val host = runCatching { URI(url).host?.lowercase() }.getOrNull() ?: continue
            if (!url.startsWith("http://", ignoreCase = true) && !url.startsWith("https://", ignoreCase = true)) continue
            if (host in LOCAL_HOSTS) continue
            val hash = blobHash(url)
            if (hash != null && isStoredLocally(hash)) continue
            seen += url
        }
        return seen.toList()
    }

    /** The SHA-256 a Blossom-style link is named by (`…/<64 hex>[.ext]`), lower-cased; null for any other link. */
    fun blobHash(url: String): String? {
        val path = runCatching { URI(url).path }.getOrNull() ?: return null
        val name = path.substringAfterLast('/').substringBefore('.')
        return name.lowercase().takeIf { it.length == 64 && it.all { c -> c in '0'..'9' || c in 'a'..'f' } }
    }

    /** The owner's notes filter for one page; [until] pages back from the oldest seen. */
    fun pageFilter(owner: String, until: Long?): String =
        if (until == null) {
            """{"kinds":[1],"authors":["$owner"],"limit":$PAGE}"""
        } else {
            """{"kinds":[1],"authors":["$owner"],"until":$until,"limit":$PAGE}"""
        }

    /**
     * Every note of [owner] the store gives, newest first, page by page back to the oldest. [fetch] runs one
     * [pageFilter]; each next page starts at the oldest note seen (`until` is inclusive, so that note comes again
     * and is not new). It ends on a page with no new note. It used to end on any page shorter than [PAGE], and the
     * store's 250 cap made that the first one: only the newest 250 notes were ever scanned.
     */
    suspend fun collect(owner: String, fetch: suspend (String) -> List<JsonObject>): List<Note> {
        val notes = LinkedHashMap<String, Note>()
        var until: Long? = null
        for (page in 0 until MAX_PAGES) {
            val fresh = fetch(pageFilter(owner, until)).mapNotNull(::parse)
                .filter { it.pubkey == owner && notes.putIfAbsent(it.id, it) == null }
            if (fresh.isEmpty()) break
            until = fresh.minOf { it.createdAt }
        }
        return notes.values.toList()
    }

    /** id, created_at, content and tags of a raw event; null when it is not a usable note. */
    fun parse(event: JsonObject): Note? = runCatching {
        Note(
            id = event["id"]?.jsonPrimitive?.contentOrNull ?: return null,
            createdAt = event["created_at"]?.jsonPrimitive?.longOrNull ?: return null,
            pubkey = event["pubkey"]?.jsonPrimitive?.contentOrNull.orEmpty(),
            content = event["content"]?.jsonPrimitive?.contentOrNull.orEmpty(),
            tags = (event["tags"] as? JsonArray).orEmpty().map { tag ->
                tag.jsonArray.mapNotNull { it.jsonPrimitive.contentOrNull }
            },
        )
    }.getOrNull()

    data class Note(val id: String, val createdAt: Long, val pubkey: String, val content: String, val tags: List<List<String>>)
}
