package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ModePostsTest {
    @Test
    fun divineTagsMatchDivineShape() {
        val tags = DivinePost.tags(
            videoUrl = "https://b.example/abc", videoSha256 = "abc", videoBytes = 42,
            posterUrl = "https://b.example/p", width = 1080, height = 1920,
            durationSeconds = 5.4, title = "Plant #green", caption = "", publishedAt = 100,
        )
        assertEquals(listOf("d", "abc"), tags[0])
        assertEquals(
            listOf("imeta", "url https://b.example/abc", "m video/mp4", "image https://b.example/p",
                "dim 1080x1920", "x abc", "size 42"),
            tags[1],
        )
        assertTrue(listOf("title", "Plant #green") in tags)
        assertTrue(listOf("duration", "5") in tags)
        assertTrue(listOf("t", "green") in tags)
    }

    @Test
    fun recipeIsWrittenAsZapCookingDoes() {
        val draft = LongFormDraft(
            title = "Mai Tai", summary = "Fruity", body = "",
            recipe = LongFormDraft.Recipe("", "3 min", "1", "- 4 cl rum\n2 cl curaçao\n\n", "1. Fill glass\n2) Pour", "Cocktail, drinks"),
            identifier = "mai-tai-x",
        )
        assertEquals(
            "## Details\n\n- 🍳 Cook time: 3 min\n- 🍽️ Servings: 1\n\n" +
                "## Ingredients\n\n- 4 cl rum\n- 2 cl curaçao\n\n## Directions\n\n1. Fill glass\n2. Pour",
            draft.content(),
        )
        val t = draft.tags(7).filter { it[0] == "t" }.map { it[1] }
        assertEquals(listOf("zapcooking", "nostrcooking", "zapcooking-cocktail", "zapcooking-drinks"), t)
    }

    @Test
    fun articleSlugAndBody() {
        assertEquals("hello-world", LongFormDraft.slug("  Hello, World! "))
        assertEquals("post", LongFormDraft.slug("!!!"))
        val draft = LongFormDraft(title = "Hi", summary = "", body = "  text  ")
        assertEquals("text", draft.content())
        assertTrue(draft.identifier.startsWith("hi-"))
        assertTrue(draft.tags(1).none { it[0] == "summary" })
    }
}
