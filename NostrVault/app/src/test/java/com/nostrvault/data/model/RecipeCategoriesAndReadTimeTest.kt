package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RecipeCategoriesAndReadTimeTest {
    private fun recipe(id: String, vararg topics: String) = FeedNote.fromEvent(
        id = id, pubkey = "pk", content = "body",
        tags = listOf(listOf("d", id), listOf("t", "zapcooking")) + topics.map { listOf("t", it) },
        createdAt = 1_700_000_000L, kind = ArticleMeta.KIND,
    )

    @Test fun categoriesRankByRecipesThenName() {
        val recipes = listOf(
            recipe("1", "zapcooking-Dessert", "zapcooking-dessert", "zapcooking-beef"),
            recipe("2", "zapcooking-beef", "nostrcooking"),
            recipe("3", "zapcooking-vegan", "zapcooking-"),
        )
        // Dessert twice on one recipe counts once; "zapcooking-" alone is no category.
        assertEquals(listOf("beef", "dessert", "vegan"), RecipeTopics.topCategories(recipes))
        assertEquals(listOf("1", "2"), RecipeTopics.filter(recipes, "beef").map { it.id })
        assertEquals(recipes, RecipeTopics.filter(recipes, null))
    }

    @Test fun categoryChipsAreCapped() {
        val recipes = (1..30).map { recipe("$it", "zapcooking-c$it") }
        assertEquals(RecipeTopics.MAX_CATEGORIES, RecipeTopics.topCategories(recipes).size)
    }

    @Test fun readingTimeRoundsUpAt200Wpm() {
        assertNull(ArticleMeta.readingTimeMinutes("  \n "))
        assertEquals(1, ArticleMeta.readingTimeMinutes("one two"))
        assertEquals(1, ArticleMeta.readingTimeMinutes(List(200) { "w" }.joinToString(" ")))
        assertEquals(2, ArticleMeta.readingTimeMinutes(List(201) { "w" }.joinToString("\n")))
    }
}
