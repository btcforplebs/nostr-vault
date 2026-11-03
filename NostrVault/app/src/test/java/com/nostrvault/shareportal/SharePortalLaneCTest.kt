package com.nostrvault.shareportal

import com.nostrvault.service.shareportal.handlers.BookmarkShareTags
import com.nostrvault.service.shareportal.handlers.ProfileShareTarget
import com.nostrvault.shareportal.ShareFixtures.str
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Share portal lane C: who a profile share names, and how Save for later edits the bookmark list. Same fixtures as
 * HavenApp MediaLogicTests SharePortalLaneCTests.swift.
 */
class SharePortalLaneCTest {
    private fun strings(e: Any?): List<String>? = (e as? JsonArray)?.map { it.jsonPrimitive.content }
    private fun tags(e: Any?): List<List<String>>? =
        if (e == null || e is JsonNull) null else (e as JsonArray).map { t -> t.jsonArray.map { it.jsonPrimitive.content } }

    @Test fun profileTargetFixtures() {
        val cases = ShareFixtures.load("profile-cases.json")["cases"]!!.jsonArray
        assertTrue(cases.size >= 10)
        for (c in cases.map { it.jsonObject }) {
            val name = c.str("name")
            val s = c["source"]!!.jsonObject
            assertEquals(name, strings(c["identifiers"]), ProfileShareTarget.identifiers(s.str("url"), s.str("text"), s.str("selection")))
            assertEquals(name, strings(c["pubkeys"]),
                ProfileShareTarget.pubkeys(s.str("url"), s.str("text"), s.str("selection"), TestNip19::pubkey))
        }
    }

    @Test fun profileTargetStopsAtTheCap() {
        val one = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        val many = "qpzry9x8gf2tvdw0s3jn54khce6mua7l".take(30).map { one.dropLast(1) + it }
        assertEquals(30, many.toSet().size)
        assertEquals(many.take(ProfileShareTarget.MAX_IDENTIFIERS), ProfileShareTarget.identifiers(null, many.joinToString(" "), null))
    }

    @Test fun bookmarkUrlFixtures() {
        for (u in ShareFixtures.load("bookmark-cases.json")["urls"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(u.toString(), u.str("url"), BookmarkShareTags.url(u.str("raw")))
        }
    }

    @Test fun bookmarkAddFixtures() {
        val cases = ShareFixtures.load("bookmark-cases.json")["cases"]!!.jsonArray
        assertTrue(cases.size >= 7)
        for (c in cases.map { it.jsonObject }) {
            val name = c.str("name")
            val got = BookmarkShareTags.adding(c.str("url")!!, tags(c["public"]).orEmpty(), tags(c["private"]).orEmpty(),
                c["privately"]!!.jsonPrimitive.boolean)
            val expect = c["expect"]!!.jsonObject
            val want = when (expect.str("already")) {
                "public" -> BookmarkShareTags.Change.AlreadyPublic
                "private" -> BookmarkShareTags.Change.AlreadyPrivate
                else -> tags(expect["public"])?.let { BookmarkShareTags.Change.PublicTags(it) }
                    ?: BookmarkShareTags.Change.PrivateTags(tags(expect["private"])!!)
            }
            assertEquals(name, want, got)
        }
    }

    /** The merged-list writer signs replaceable lists; a new caller is a new way to write one (UserListSignGuardTest
     *  doesn't see it: it takes its kind as an argument). Review the caller, then add it here. */
    @Test fun onlyTheseFilesWriteThroughPublishMergedList() {
        val root = java.io.File("src/main/java")
        val callers = root.walkTopDown().filter { it.isFile && it.extension == "kt" }
            .filter { Regex("(?<!fun NostrService\\.)\\bpublishMergedList\\s*\\(").containsMatchIn(it.readText()) }
            .map { it.relativeTo(root).path }.toSortedSet()
        assertEquals(
            sortedSetOf(
                "com/nostrvault/service/nostr/NostrServiceListPublishing.kt",
                // Share Portal Save for later: one r tag on the 10003, Tron review (private bookmarks).
                "com/nostrvault/service/nostr/NostrServiceBookmarkShare.kt",
            ),
            callers,
        )
        val share = java.io.File(root, "com/nostrvault/service/nostr/NostrServiceBookmarkShare.kt").readText()
        assertTrue("only kind 10003", share.contains("publishMergedList(\n        BookmarkShareTags.KIND,"))
        assertEquals(10003, BookmarkShareTags.KIND)
    }

    @Test fun bookmarkPrivatePartFixtures() {
        for (p in ShareFixtures.load("bookmark-cases.json")["private_parts"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(p.str("name"), tags(p["tags"]), BookmarkShareTags.privateTags(p.str("plaintext")!!))
        }
        // What it writes, it reads back the same; slashes as they are, like other apps write them.
        val written = listOf(listOf("r", "https://x.example/a?b=c&d=é"), listOf("e", "aa"))
        assertEquals(written, BookmarkShareTags.privateTags(BookmarkShareTags.json(written)))
        assertFalse(BookmarkShareTags.json(written).contains("\\/"))
    }
}

/** NIP-19 npub / nprofile → hex with the checksum checked, for the fixtures (the app uses HavenBridge, which is native). */
private object TestNip19 {
    private const val CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    private fun polymod(values: List<Int>): Int {
        val gen = intArrayOf(0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)
        var chk = 1
        for (v in values) {
            val b = chk ushr 25
            chk = ((chk and 0x1ffffff) shl 5) xor v
            for (i in 0 until 5) if ((b ushr i) and 1 == 1) chk = chk xor gen[i]
        }
        return chk
    }

    fun pubkey(s: String): String? {
        val sep = s.lastIndexOf('1')
        if (sep < 1) return null
        val hrp = s.substring(0, sep)
        val data = s.substring(sep + 1).map { CHARSET.indexOf(it).takeIf { i -> i >= 0 } ?: return null }
        if (data.size < 6) return null
        val expanded = hrp.map { it.code ushr 5 } + 0 + hrp.map { it.code and 31 }
        if (polymod(expanded + data) != 1) return null
        var acc = 0; var bits = 0
        val bytes = mutableListOf<Int>()
        for (v in data.dropLast(6)) {
            acc = (acc shl 5) or v; bits += 5
            while (bits >= 8) { bits -= 8; bytes += (acc ushr bits) and 0xff }
        }
        val raw = when (hrp) {
            "npub" -> bytes.takeIf { it.size == 32 }
            "nprofile" -> {
                var i = 0; var found: List<Int>? = null
                while (i + 1 < bytes.size) {
                    val t = bytes[i]; val l = bytes[i + 1]
                    if (i + 2 + l > bytes.size) break
                    if (t == 0 && l == 32 && found == null) found = bytes.subList(i + 2, i + 2 + l)
                    i += 2 + l
                }
                found
            }
            else -> null
        } ?: return null
        return raw.joinToString("") { "%02x".format(it) }
    }
}
