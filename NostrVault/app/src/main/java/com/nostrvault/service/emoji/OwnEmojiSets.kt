package com.nostrvault.service.emoji

import com.nostrvault.service.EmojiListParse
import com.nostrvault.service.EmojiListRepository
import com.nostrvault.service.ListHistory
import com.nostrvault.service.ListShrinkRule
import com.nostrvault.service.ListVersion

/**
 * "Your old sets" in Find emoji sets (Logen 2026-11-13, "we need that too"): the person's own 30030 sets found on
 * their relays, in the vault and in the vault's list history, that aren't working for them now. A set shows when
 * it isn't in their 10030, or when its newest copy looks like a wipe of an older one ([ListShrinkRule.shrank]).
 * Pure; [OwnEmojiSetFinder] reads and saves. Apple twin: Tal's next.
 */
object OwnEmojiSets {
    data class OldSet(
        val address: String,
        /** The version Add back brings: its title and emoji. */
        val set: EmojiListRepository.EmojiSet,
        val version: ListVersion,
        /** The newest copy found, when it isn't [version]. */
        val newest: ListVersion,
        /** Add back signs [version]'s emoji again as a new copy of the set (the newest one lost them). */
        val restore: Boolean,
        /** In the 10030 now: Add back only restores. */
        val listed: Boolean,
    ) {
        val newestCount: Int get() = ListShrinkRule.itemCount(newest)
    }

    /**
     * The old sets among [versions] (any mix of relay, vault and history copies, duplicates fine) by [owner],
     * against the addresses [listed] in the 10030 now; newest first. A set none of whose copies has an emoji is
     * left out: there is nothing to bring back.
     */
    fun pick(versions: List<ListVersion>, owner: String, listed: Set<String>): List<OldSet> =
        versions.asSequence()
            .filter { it.pubkey == owner && it.kind == KIND }
            .distinctBy { it.id }
            .mapNotNull { v -> address(v)?.let { it to v } }
            .groupBy({ it.first }, { it.second })
            .mapNotNull { (address, copies) -> oldSet(address, copies.sortedWith(ListHistory.newerFirst), address in listed) }
            .sortedWith(compareByDescending<OldSet> { it.version.createdAt }.thenBy { it.address })

    private fun oldSet(address: String, newestFirst: List<ListVersion>, listed: Boolean): OldSet? {
        val newest = newestFirst.first()
        // The fullest older copy the newest one wiped, the newer of two the same size.
        val wiped = newestFirst.drop(1)
            .filter { ListShrinkRule.shrank(it, newest) }
            .maxWithOrNull(compareBy<ListVersion> { emojiCount(address, it) }.thenBy { it.createdAt })
            ?.takeIf { emojiCount(address, it) > 0 }
        val version = wiped ?: newest
        val set = EmojiListParse.set(address, version.tags)
        if (set.emojis.isEmpty()) return null
        if (listed && wiped == null) return null
        return OldSet(address, set, version, newest, restore = wiped != null, listed = listed)
    }

    private fun emojiCount(address: String, v: ListVersion) = EmojiListParse.set(address, v.tags).emojis.size

    /** `30030:<pubkey>:<d>` for a valid set copy, or null. */
    fun address(v: ListVersion): String? {
        if (v.kind != KIND) return null
        val d = v.tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1) ?: return null
        return "$KIND:${v.pubkey}:$d".takeIf { EmojiListParse.setRef(it) != null }
    }

    const val KIND = 30030
}
