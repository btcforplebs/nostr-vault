package com.nostrvault.ui.screens.dashboard

/**
 * What the vault holds, grouped the way the Vault tab names things, from
 * NIP-45 COUNTs on the vault's own relays (StatsService.fetchCountsByKind).
 * Port of iOS `VaultContents`, so both apps list the same groups and numbers.
 *
 * The dashboard used to show four tiles counted one way, a Storage card and
 * Relay details › What's stored counted another, and a per-kind sheet a third.
 * This is the one source for all of them.
 */
internal object VaultDashboardContents {

    data class Group(
        val id: String,
        val title: String,
        val kinds: List<Int>,
        /** False where "by you" means nothing: a gift wrap is signed by a throwaway key. */
        val countsYours: Boolean = true,
    )

    /** One group's line: its total, how many you signed, and its kinds that hold anything. */
    data class GroupRow(val group: Group, val count: Int, val yours: Int?, val kinds: List<KindRow>)

    /** A kind and its count; [kind] null for the events whose kind was not asked about. */
    data class KindRow(val kind: Int?, val count: Int) {
        val title: String get() = kind?.let(::kindName) ?: "Kinds not listed"
    }

    /** The groups, in the order the dashboard lists them (iOS `VaultContents.groups`). */
    val groups = listOf(
        Group("notes", "Notes", listOf(1, 6, 1111, 1068)),
        Group("articles", "Articles", listOf(30023, 30024)),
        Group("highlights", "Highlights", listOf(9802)),
        Group("reactions", "Reactions", listOf(7)),
        // Receipts are signed by the wallet's server, so none are "yours" (iOS too).
        Group("zaps", "Zaps", listOf(9734, 9735), countsYours = false),
        Group("messages", "Messages", listOf(4, 1059), countsYours = false),
        Group(
            "profile", "Profile and lists",
            listOf(0, 3, 10000, 10001, 10002, 10003, 10005, 10006, 10015, 10030, 10050, 10063, 30000, 30001, 30002, 30003),
        ),
    )

    /** Kinds counted one by one beyond the groups, so "Other" can say what it holds. */
    val otherKinds = listOf(5, 8, 9, 16, 20, 21, 22, 1063, 1311, 1808, 30008, 30009, 30030, 30078)

    /** The kinds counted for the active account alone. */
    val yourKinds: List<Int> get() = groups.filter { it.countsYours }.flatMap { it.kinds }

    fun kindName(kind: Int): String = kindNames[kind] ?: "Kind $kind"

    private val kindNames = mapOf(
        0 to "Profile", 1 to "Short notes", 3 to "Follow list", 4 to "Direct messages (old style)",
        5 to "Deletions", 6 to "Reposts", 7 to "Reactions", 8 to "Badge awards", 9 to "Chat messages",
        16 to "Generic reposts", 20 to "Pictures", 21 to "Videos", 22 to "Short videos",
        1059 to "Gift-wrapped messages", 1063 to "File details", 1068 to "Polls", 1111 to "Comments",
        1311 to "Live chat", 1808 to "Audio tracks", 9734 to "Zap requests", 9735 to "Zap receipts",
        9802 to "Highlights", 10000 to "Mute list", 10001 to "Pinned notes", 10002 to "Relay list",
        10003 to "Bookmarks", 10005 to "Public chats", 10006 to "Blocked relays", 10015 to "Interests",
        10030 to "Emoji list", 10050 to "Message relays", 10063 to "Media servers",
        30000 to "People lists", 30001 to "Generic lists", 30002 to "Relay sets", 30003 to "Bookmark sets",
        30008 to "Profile badges", 30009 to "Badge definitions", 30023 to "Articles", 30024 to "Article drafts",
        30030 to "Emoji sets", 30078 to "App data",
    )

    /**
     * The group rows, empty ones left out. "Other" is the total less the
     * named groups: its listed kinds, plus "Kinds not listed" for the rest.
     * [yoursByKind] null (not counted for this account) shows no "yours".
     */
    fun groupRows(total: Int, byKind: Map<Int, Int>, yoursByKind: Map<Int, Int>?): List<GroupRow> {
        val named = groups.map { g ->
            GroupRow(
                group = g,
                count = g.kinds.sumOf { byKind[it] ?: 0 },
                yours = if (g.countsYours && yoursByKind != null) g.kinds.sumOf { yoursByKind[it] ?: 0 } else null,
                kinds = kindRows(g.kinds, byKind),
            )
        }
        val namedTotal = named.sumOf { it.count }
        val listed = kindRows(otherKinds, byKind)
        val unlisted = maxOf(0, total - namedTotal - listed.sumOf { it.count })
        val otherRows = if (unlisted > 0) (listed + KindRow(null, unlisted)).sortedByDescending { it.count } else listed
        val other = GroupRow(
            group = Group("other", "Other", otherKinds, countsYours = false),
            count = maxOf(0, total - namedTotal),
            yours = null,
            kinds = otherRows,
        )
        return (named + other).filter { it.count > 0 }
    }

    /** The kinds that hold anything, largest first. */
    private fun kindRows(kinds: List<Int>, byKind: Map<Int, Int>): List<KindRow> =
        kinds.mapNotNull { k -> (byKind[k] ?: 0).takeIf { it > 0 }?.let { KindRow(k, it) } }
            .sortedByDescending { it.count }

    // ── Media files ─────────────────────────────────────────────

    enum class MediaType(val title: String) { IMAGE("Images"), VIDEO("Videos"), AUDIO("Audio"), OTHER("Other") }

    data class MediaBucket(val type: MediaType, val count: Int = 0, val size: Long = 0)

    data class Media(val buckets: List<MediaBucket>) {
        val count: Int get() = buckets.sumOf { it.count }
        val size: Long get() = buckets.sumOf { it.size }
    }

    /** The files the Vault tab's media grid lists: a 64-hex sha256 name (MediaGalleryViewModel). */
    fun isListedBlob(nameWithoutExtension: String): Boolean =
        nameWithoutExtension.length == 64 && nameWithoutExtension.all { it in "0123456789abcdef" }

    /** A file's type from its first bytes, never from its name or `/list`. */
    fun mediaType(header: ByteArray): MediaType {
        fun at(i: Int, text: String) = header.size >= i + text.length &&
            text.indices.all { header[i + it] == text[it].code.toByte() }
        fun byte(i: Int) = if (header.size > i) header[i].toInt() and 0xFF else -1
        val brand = if (at(4, "ftyp") && header.size >= 12) String(header, 8, 4, Charsets.US_ASCII) else null
        return when {
            byte(0) == 0xFF && byte(1) == 0xD8 -> MediaType.IMAGE
            byte(0) == 0x89 && at(1, "PNG") -> MediaType.IMAGE
            at(0, "GIF8") -> MediaType.IMAGE
            at(0, "RIFF") && at(8, "WEBP") -> MediaType.IMAGE
            brand != null && brand in setOf("heic", "heix", "hevc", "mif1", "msf1", "avif") -> MediaType.IMAGE
            brand != null && brand.startsWith("M4A") -> MediaType.AUDIO
            brand != null -> MediaType.VIDEO
            byte(0) == 0x1A && byte(1) == 0x45 && byte(2) == 0xDF && byte(3) == 0xA3 -> MediaType.VIDEO
            at(0, "ID3") || at(0, "OggS") || at(0, "fLaC") || (at(0, "RIFF") && at(8, "WAVE")) -> MediaType.AUDIO
            byte(0) == 0xFF && byte(1) >= 0xE0 -> MediaType.AUDIO // MPEG audio frame sync
            else -> MediaType.OTHER
        }
    }
}
