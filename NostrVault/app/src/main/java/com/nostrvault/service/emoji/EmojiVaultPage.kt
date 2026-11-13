package com.nostrvault.service.emoji

import com.nostrvault.fips.EmojiNote
import com.nostrvault.service.EmojiListParse
import com.nostrvault.service.EmojiListRepository

/** What the Emoji page lists (custom emoji plan §4.1 "Emoji page"). Pure, for the tests. */
object EmojiVaultPage {
    data class Tile(val code: String, val url: String, val saved: Boolean, val dead: Boolean)

    data class SetBlock(
        val address: String,
        val title: String,
        val author: String,
        val image: String?,
        val tiles: List<Tile>,
        /** In the 10030 now; false: only saved copies still name it. */
        val listed: Boolean,
    ) {
        val savedCount: Int get() = tiles.count { it.saved }
    }

    /**
     * One block per set: the 10030's [sets] in its order (each emoji saved or "not saved"), then sets only the saved
     * copies or emoji notes name, from those. Loose emoji are never listed (pick 6).
     */
    fun blocks(
        sets: List<EmojiListRepository.EmojiSet>,
        saved: List<EmojiVaultStore.Saved>,
        notes: List<EmojiNote>,
        deadUrls: Set<String>,
    ): List<SetBlock> {
        val copies = saved.map { Triple(it.sha256, it.codes, it.sets) } + notes.map { Triple(it.sha256, it.codes, it.sets) }
        val savedUrls = copies.flatMap { (_, codes, _) -> codes.mapNotNull { it.getOrNull(1) } }.toSet()
        val listed = sets.map { set ->
            SetBlock(
                set.address, set.title, set.author, set.image,
                set.emojis.map { Tile(it.shortcode, it.url, it.url in savedUrls, it.url !in savedUrls && it.url in deadUrls) },
                listed = true,
            )
        }
        val known = sets.map { it.address }.toSet()
        val others = LinkedHashMap<String, MutableList<Tile>>()
        for ((_, codes, addrs) in copies) for (a in addrs) {
            if (a in known) continue
            val tiles = others.getOrPut(a) { mutableListOf() }
            for (c in codes) if (c.size >= 2 && tiles.none { it.code == c[0] }) tiles += Tile(c[0], c[1], saved = true, dead = false)
        }
        return listed + others.map { (a, tiles) ->
            val ref = EmojiListParse.setRef(a)
            SetBlock(a, ref?.d?.takeIf { it.isNotBlank() } ?: "Emoji set", ref?.pubkey.orEmpty(), null, tiles, listed = false)
        }
    }
}
