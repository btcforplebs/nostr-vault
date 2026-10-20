package com.nostrvault.service

import android.content.Context
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.GatedArticle
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Opens gated ("zap N sats to unlock") articles this reader already
 * unlocked. Nostr Vault does not unlock them: no pay button and no key
 * request, so a locked article stays locked. A key fetched by an earlier
 * version is still on the device, and still opens its article.
 */
@Singleton
class GatedArticleService @Inject constructor(
    @ApplicationContext context: Context,
    private val nostrService: NostrService,
) {
    private val prefs = context.getSharedPreferences("gated_article_keys", Context.MODE_PRIVATE)

    /** The signed-in account; a key belongs to one reader. */
    val activeReader: String get() = nostrService.activeHexPubkey

    /**
     * Keys already fetched, by reader pubkey and article coordinate. A key
     * belongs to the article address, not one version of it, so an edit keeps
     * it; a key that stops working is dropped.
     */
    private fun cacheKey(reader: String, coordinate: String) = "$reader|$coordinate"

    /** The article body if this reader unlocked it before, else null (locked). */
    fun open(note: FeedNote, gated: GatedArticle): String? {
        val reader = nostrService.activeHexPubkey
        if (reader.isEmpty()) return null
        val identifier = note.tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1) ?: return null
        val stored = cacheKey(reader, "${note.kind}:${note.pubkey}:$identifier")
        val key = prefs.getString(stored, null) ?: return null
        gated.decrypt(key)?.let { return it }
        prefs.edit().remove(stored).apply()
        return null
    }
}
