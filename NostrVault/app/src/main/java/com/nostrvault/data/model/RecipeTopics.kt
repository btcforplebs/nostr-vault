package com.nostrvault.data.model

/** `t` topics zap.cooking publishes recipes under; category tags are `zapcooking-<category>`. */
object RecipeTopics {
    const val CATEGORY_PREFIX = "zapcooking-"
    val BASE = listOf("zapcooking", "nostrcooking")

    /** True when this note carries one of the recipe topics. */
    fun matches(tags: List<List<String>>): Boolean = tags.any { tag ->
        tag.size >= 2 && tag[0] == "t" && tag[1].lowercase().let { topic ->
            topic in BASE || topic.startsWith(CATEGORY_PREFIX)
        }
    }

    /** How many category chips the bar shows. */
    const val MAX_CATEGORIES = 12

    /** The `zapcooking-<category>` names on one recipe, once each. */
    fun categoriesOf(tags: List<List<String>>): Set<String> = tags.asSequence()
        .filter { it.size >= 2 && it[0] == "t" }
        .map { it[1].lowercase() }
        .filter { it.startsWith(CATEGORY_PREFIX) }
        .map { it.removePrefix(CATEGORY_PREFIX) }
        .filter { it.isNotEmpty() }
        .toSet()

    /**
     * The most common categories in [recipes], for the chip bar. Capped: a
     * 200-recipe page carries close to 300 distinct tags, most used once.
     * Ranked by how many recipes carry it, then alphabetically.
     * iOS: RecipeFeedService.categories.
     */
    fun topCategories(recipes: List<FeedNote>): List<String> {
        val counts = HashMap<String, Int>()
        for (recipe in recipes) for (name in categoriesOf(recipe.tags)) counts[name] = (counts[name] ?: 0) + 1
        return counts.entries
            .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
            .take(MAX_CATEGORIES)
            .map { it.key }
    }

    private val TIMESTAMP_IN_TITLE = Regex("\\b1[6-9][0-9]{8}\\b")
    private val WHITESPACE = Regex("\\s+")

    /**
     * Client test publishes, not recipes. iOS: RecipeFeedService.looksLikeTestPost.
     *
     * Measured against 500 live zapcooking/nostrcooking events on 2026-09-05:
     * these two rules drop 20 events, and every one of them is a test post
     * ("iOS 2.3 Live Publish 1788113645", "E2E Curry", "Ppp"). Deliberately
     * narrow: an Ingredients-heading rule also dropped real recipes.
     */
    fun looksLikeTestPost(tags: List<List<String>>, content: String): Boolean {
        val title = tags.firstOrNull { it.size >= 2 && it[0] == "title" }?.get(1) ?: ""
        // A unix timestamp in the title means a machine generated it. Real
        // recipe names do not carry a 10-digit number starting with 16-19.
        if (TIMESTAMP_IN_TITLE.containsMatchIn(title)) return true
        // A recipe needs ingredients and directions. Under 30 words is not
        // one; the shortest real recipe in the sample was 39.
        return content.split(WHITESPACE).count { it.isNotEmpty() } < 30
    }

    /** Recipes in [category], or all of them for null. */
    fun filter(recipes: List<FeedNote>, category: String?): List<FeedNote> =
        if (category == null) recipes else recipes.filter { category in categoriesOf(it.tags) }
}
