package com.nostrvault.data.model

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecipeTopicsTest {

    private fun t(vararg topics: String) = topics.map { listOf("t", it) }

    @Test fun `base topics match`() {
        assertTrue(RecipeTopics.matches(t("zapcooking")))
        assertTrue(RecipeTopics.matches(t("nostrcooking")))
    }

    @Test fun `category tags match`() {
        // zap.cooking files recipes under zapcooking-<category>; a recipe
        // carrying only a category tag is still a recipe.
        assertTrue(RecipeTopics.matches(t("zapcooking-dessert")))
        assertTrue(RecipeTopics.matches(t("food", "zapcooking-beef")))
    }

    @Test fun `case is ignored`() {
        assertTrue(RecipeTopics.matches(t("ZapCooking")))
        assertTrue(RecipeTopics.matches(t("ZAPCOOKING-Dessert")))
    }

    private val recipe = (1..40).joinToString(" ") { "word$it" }
    private fun titled(title: String) = listOf(listOf("title", title))

    @Test fun `test posts are dropped`() {
        // A unix timestamp in the title, whatever the body.
        assertTrue(RecipeTopics.looksLikeTestPost(titled("iOS 2.3 Live Publish 1788113645"), recipe))
        assertTrue(RecipeTopics.looksLikeTestPost(titled("1699999999"), recipe))
        // Under 30 words is not a recipe.
        assertTrue(RecipeTopics.looksLikeTestPost(titled("E2E Curry"), "Ppp"))
        assertTrue(RecipeTopics.looksLikeTestPost(titled("Toast"), (1..29).joinToString(" \n") { "w$it" }))
    }

    @Test fun `real recipes are kept`() {
        assertFalse(RecipeTopics.looksLikeTestPost(titled("Grandma's Curry"), recipe))
        assertFalse(RecipeTopics.looksLikeTestPost(emptyList(), (1..30).joinToString(" ") { "w$it" }))
        // A year or a 9-digit number in a title is not a timestamp.
        assertFalse(RecipeTopics.looksLikeTestPost(titled("Christmas Pudding 2025"), recipe))
        assertFalse(RecipeTopics.looksLikeTestPost(titled("Batch 169999999"), recipe))
        // Eleven digits is not a unix timestamp either.
        assertFalse(RecipeTopics.looksLikeTestPost(titled("Order 16999999999"), recipe))
    }

    @Test fun `unrelated topics do not match`() {
        assertFalse(RecipeTopics.matches(t("cooking")))
        assertFalse(RecipeTopics.matches(t("food", "recipe")))
        assertFalse(RecipeTopics.matches(emptyList()))
    }

    @Test fun `only t tags count`() {
        // A title that happens to read "zapcooking" is not a topic.
        assertFalse(RecipeTopics.matches(listOf(listOf("title", "zapcooking"))))
        assertFalse(RecipeTopics.matches(listOf(listOf("t"))))
    }
}
