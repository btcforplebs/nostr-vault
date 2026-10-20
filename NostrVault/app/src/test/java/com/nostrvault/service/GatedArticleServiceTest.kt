package com.nostrvault.service

import android.content.Context
import android.content.SharedPreferences
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.GatedArticle
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * No zap-to-unlock (Logen, 2026-10-20): a locked article stays locked and
 * nothing is signed or requested to unlock it; one this reader unlocked
 * before still opens from its stored key.
 */
class GatedArticleServiceTest {
    private val author = "adc14fa3ad590856dd8b80815d367f7c1e6735ad00fd98a86d002fbe9fb535e1"
    private val reader = "b".repeat(64)
    private val tags = listOf(
        listOf("d", "d6711eb7-0703-48bb-9fd5-61b96e57283c"),
        listOf("encrypted", "aes-256-gcm",
            "AQIDBAUGBwgJCgsMWVJSyIdkwGGGkd2kTIZsMgf2yoQI++wXRPfUyTlbSWgkrDfVohPZs+M3pLRXdVxSVrYS98ZTHe8/9vfNgHI8mpNeo5hR6fphTQME+3RawQ==",
            "https://api.fanfares.live/request-key"),
        listOf("price", "42", "SATS"),
    )
    private val note = FeedNote(id = "n1", pubkey = author, content = "Teaser.", createdAt = java.util.Date(0), tags = tags, kind = 30023)
    private val gated = GatedArticle.from(note)!!
    private val storedAt = "$reader|30023:$author:d6711eb7-0703-48bb-9fd5-61b96e57283c"
    private val key = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

    private val editor = mockk<SharedPreferences.Editor>(relaxed = true)
    private val prefs = mockk<SharedPreferences>().also { every { it.edit() } returns editor }
    private val nostr = mockk<NostrService>(relaxed = true).also { every { it.activeHexPubkey } returns reader }

    private fun service(): GatedArticleService {
        val context = mockk<Context>()
        every { context.getSharedPreferences(any(), any()) } returns prefs
        return GatedArticleService(context, nostr)
    }

    @Test fun aLockedArticleStaysLockedAndNothingIsSigned() {
        every { prefs.getString(storedAt, null) } returns null
        assertNull(service().open(note, gated))
        coVerify(exactly = 0) { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test fun anArticleUnlockedBeforeStillOpens() {
        every { prefs.getString(storedAt, null) } returns key
        assertEquals("# Whose life is this?\n\nThe full article — with ünïcode ⚡.", service().open(note, gated))
    }

    @Test fun aStoredKeyThatNoLongerOpensIsDroppedAndStaysLocked() {
        every { prefs.getString(storedAt, null) } returns "0".repeat(64)
        assertNull(service().open(note, gated))
        verify { editor.remove(storedAt) }
        coVerify(exactly = 0) { nostr.signEventAsync(any(), any(), any(), any(), any(), any(), any()) }
    }
}
