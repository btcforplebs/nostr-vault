package com.nostrvault.ui.screens.profile

import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Date

/** Article card text and the media tile backup badge, as iOS ArticleCardView and MediaGridItem. */
class ProfileContentCardsTest {
    private val hash = "a".repeat(64)
    private val mirrors = listOf("https://blossom.example")

    @Test
    fun badgeShowsForABlossomFileOnceYouHaveAServer() {
        assertEquals(hash, ProfileTileBackup.badgeHash("https://cdn.example/$hash.jpg", mirrors))
        assertEquals(hash, ProfileTileBackup.badgeHash("https://cdn.example/${hash.uppercase()}?x=1", mirrors))
    }

    @Test
    fun noBadgeWithoutAServerOrWithoutAHash() {
        assertNull(ProfileTileBackup.badgeHash("https://cdn.example/$hash.jpg", emptyList()))
        assertNull(ProfileTileBackup.badgeHash("https://i.example/photo.jpg", mirrors))
    }

    @Test
    fun topicsAreTheFirstThreeLowercased() {
        val tags = listOf(listOf("t", "Bitcoin"), listOf("d", "x"), listOf("t", "nostr"), listOf("t", "bitcoin"),
            listOf("t", ""), listOf("t", "Art"), listOf("t", "Music"))
        assertEquals(listOf("bitcoin", "nostr", "art"), ProfileArticleCardText.topics(tags))
        assertEquals(emptyList<String>(), ProfileArticleCardText.topics(listOf(listOf("t"))))
    }

    @Test
    fun previewIsTheSummaryElseThePlainBody() {
        val note = FeedNote(id = "1", pubkey = "p", content = "# Heading\n\nSome **bold** words.", createdAt = Date(0), tags = emptyList(), kind = 30023)
        assertEquals("Mine", ProfileArticleCardText.preview(note, "Mine"))
        val plain = ProfileArticleCardText.preview(note, null)!!
        assertEquals(false, plain.contains("**") || plain.contains("#"))
    }

    @Test
    fun authorNameFallsBackToTheKeysTail() {
        assertEquals("Alice", ProfileArticleCardText.authorName("Alice", "0123456789abcdef"))
        assertEquals("npub…abcdef", ProfileArticleCardText.authorName(null, "0123456789abcdef"))
    }
}
