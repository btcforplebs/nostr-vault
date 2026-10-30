package com.nostrvault.data.model

import java.net.URI
import java.net.URLDecoder
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/**
 * A BUD-10 Blossom link: `blossom:<sha256>.<ext>?xs=<server>&as=<pubkey>&sz=<bytes>`.
 *
 * The link names a file by its hash, not by where it lives. `xs` hints at
 * servers that hold it (any number, bare domains or full URLs), `as` is the
 * author whose kind 10063 server list may hold it, and `sz` its size. A reader
 * tries the servers in turn, GETs `/<sha256>.<ext>` and keeps the bytes only
 * when they hash to the link's sha256, since any server may answer.
 * iOS: `BlossomURI.swift` (#1312). Web: `web-vault/src/net/blossom-uri.js` (#1311).
 */
data class BlossomUri(
    val sha256: String,
    /** Lowercase, no dot: "jpg", "mp4". */
    val ext: String,
    /** The `xs` servers, as https origins with no trailing slash, in the link's order. */
    val servers: List<String>,
    /** The `as` pubkey as hex, when it is one. */
    val author: String?,
    /** The `sz` byte count, when given. */
    val size: Long?,
) {
    /**
     * Where to ask, in order: the link's own servers, then the author's list,
     * then ours. Each is `<server>/<sha256>.<ext>`, once each, https only.
     */
    fun candidates(authorServers: List<String>, fallbackServers: List<String>): List<String> {
        val bases = servers + (authorServers + fallbackServers).mapNotNull(::serverOrigin)
        return bases.distinctBy { it.lowercase() }.map { "$it/$sha256.$ext" }
    }

    companion object {
        const val SCHEME = "blossom"

        private val NAME = Regex("^([0-9a-fA-F]{64})\\.([A-Za-z0-9]{1,10})$")
        private val HEX_64 = Regex("^[0-9a-f]{64}$")

        /** Where a note's text has one: the whole link, query included, up to the next space. */
        val TOKEN = Regex("""blossom:[0-9a-fA-F]{64}\.[A-Za-z0-9]{1,10}(?:\?[^\s<>"]*)?""")

        fun isUri(url: String): Boolean = url.startsWith("$SCHEME:", ignoreCase = true)

        /** Null for anything that is not a well-formed `blossom:` link. */
        fun parse(raw: String): BlossomUri? {
            val text = raw.trim()
            if (!isUri(text)) return null
            val rest = text.substring(SCHEME.length + 1)
            val name = NAME.matchEntire(rest.substringBefore('?')) ?: return null
            val query = if ('?' in rest) rest.substringAfter('?') else ""
            val servers = mutableListOf<String>()
            var author: String? = null
            var size: Long? = null
            for (pair in query.split('&')) {
                if (pair.isEmpty()) continue
                val key = pair.substringBefore('=')
                val value = runCatching { URLDecoder.decode(pair.substringAfter('=', ""), "UTF-8") }.getOrNull() ?: continue
                when (key) {
                    "xs" -> serverOrigin(value)?.let { if (servers.none { s -> s.equals(it, true) }) servers += it }
                    "as" -> if (author == null) author = value.trim().lowercase().takeIf { HEX_64.matches(it) }
                    "sz" -> if (size == null) size = value.toLongOrNull()?.takeIf { it > 0 }
                }
            }
            return BlossomUri(
                sha256 = name.groupValues[1].lowercase(),
                ext = name.groupValues[2].lowercase(),
                servers = servers,
                author = author,
                size = size,
            )
        }

        /**
         * A server as an https origin (plus any path) with no trailing slash, or
         * null: a bare host becomes `https://host`; http, other schemes, user
         * info, loopback, private-network and .local/.onion hosts are refused,
         * so a note cannot make every reader probe their own network. Same
         * rule as the web's `serverOrigin`.
         */
        fun serverOrigin(raw: String?): String? {
            var s = raw?.trim().orEmpty()
            if (s.isEmpty()) return null
            if (!Regex("^[a-zA-Z][a-zA-Z0-9+.-]*://").containsMatchIn(s)) s = "https://$s"
            val u = runCatching { URI(s) }.getOrNull() ?: return null
            if (!u.scheme.equals("https", ignoreCase = true) || u.rawUserInfo != null) return null
            if (u.rawQuery != null || u.rawFragment != null) return null
            val h = u.host?.lowercase()?.removePrefix("[")?.removeSuffix("]") ?: return null
            if (isPrivateHost(h)) return null
            val port = if (u.port != -1 && u.port != 443) ":${u.port}" else ""
            val path = u.rawPath.orEmpty().trimEnd('/')
            val host = if (':' in h) "[$h]" else h
            return "https://$host$port$path"
        }

        private val PRIVATE_V4 = listOf(
            Regex("^(127\\.|10\\.|0\\.|169\\.254\\.|192\\.168\\.)"),
            Regex("^172\\.(1[6-9]|2\\d|3[01])\\."),
            Regex("^100\\.(6[4-9]|[7-9]\\d|1[01]\\d|12[0-7])\\."),
        )

        internal fun isPrivateHost(h: String): Boolean {
            if (h == "localhost" || h.endsWith(".localhost") || h.endsWith(".local") ||
                h.endsWith(".onion") || h.endsWith(".internal")) return true
            if ('.' !in h && ':' !in h) return true
            if (PRIVATE_V4.any { it.containsMatchIn(h) }) return true
            if (h == "::1" || h == "::" || Regex("^f[cd][0-9a-f]{2}:").containsMatchIn(h) || h.startsWith("fe80:")) return true
            return false
        }

        fun sha256Hex(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

        // Note authors by sha256, for links without `as`: who posted it is
        // whose 10063 to read, wherever the link is drawn.
        private val noteAuthors = ConcurrentHashMap<String, String>()
        private const val MAX_REMEMBERED_AUTHORS = 4_000

        /** Remember who posted these links. */
        fun register(urls: List<String>, author: String) {
            for (url in urls) {
                val uri = parse(url) ?: continue
                if (noteAuthors.size >= MAX_REMEMBERED_AUTHORS) noteAuthors.clear()
                noteAuthors.putIfAbsent(uri.sha256, author)
            }
        }

        fun noteAuthor(sha256: String): String? = noteAuthors[sha256]
    }
}
