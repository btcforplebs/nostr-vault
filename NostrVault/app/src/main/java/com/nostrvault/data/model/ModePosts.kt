package com.nostrvault.data.model

import java.util.UUID

/**
 * The events the diVine, article and recipe composers publish. Port of
 * DivineComposeView.tags and LongFormDraft in the iOS app; kept apart from the
 * screens so their shape can be tested.
 */
object DivinePost {
    const val KIND = 34236

    /** Tags in the order and shape diVine's own events use. */
    fun tags(
        videoUrl: String,
        videoSha256: String,
        videoBytes: Long,
        posterUrl: String,
        width: Int,
        height: Int,
        durationSeconds: Double,
        title: String,
        caption: String,
        publishedAt: Long,
    ): List<List<String>> {
        val tags = mutableListOf<List<String>>(listOf("d", videoSha256))
        tags.add(
            listOf(
                "imeta",
                "url $videoUrl",
                "m video/mp4",
                "image $posterUrl",
                "dim ${width}x$height",
                "x $videoSha256",
                "size $videoBytes",
            )
        )
        if (title.isNotEmpty()) tags.add(listOf("title", title))
        tags.add(listOf("published_at", publishedAt.toString()))
        tags.add(listOf("duration", maxOf(1, Math.round(durationSeconds).toInt()).toString()))
        val alt = when {
            title.isNotEmpty() -> title
            caption.isNotEmpty() -> caption.take(140)
            else -> "Short video"
        }
        tags.add(listOf("alt", alt))
        tags.addAll(NoteTagging.hashtagTags("$title $caption"))
        return tags
    }
}

/** A NIP-23 long-form post (kind 30023): an article, or a recipe as zap.cooking writes them. */
data class LongFormDraft(
    val title: String,
    val summary: String,
    val body: String,
    val imageUrl: String? = null,
    val recipe: Recipe? = null,
    /** The `d` tag: a slug of the title plus a short random suffix so two
     *  posts with the same title don't replace each other. */
    val identifier: String = "${slug(title)}-${UUID.randomUUID().toString().take(6)}",
) {
    data class Recipe(
        val prepTime: String,
        val cookTime: String,
        val servings: String,
        val ingredients: String,
        val directions: String,
        val categories: String,
    )

    fun content(): String {
        val recipe = recipe ?: return body.trim()
        val parts = mutableListOf<String>()
        val notes = body.trim()
        if (notes.isNotEmpty()) parts.add("## Chef's notes\n\n$notes")
        val details = buildList {
            recipe.prepTime.trim().takeIf { it.isNotEmpty() }?.let { add("- ⏲️ Prep time: $it") }
            recipe.cookTime.trim().takeIf { it.isNotEmpty() }?.let { add("- 🍳 Cook time: $it") }
            recipe.servings.trim().takeIf { it.isNotEmpty() }?.let { add("- 🍽️ Servings: $it") }
        }
        if (details.isNotEmpty()) parts.add("## Details\n\n" + details.joinToString("\n"))
        parts.add("## Ingredients\n\n" + lines(recipe.ingredients).joinToString("\n") { "- $it" })
        parts.add(
            "## Directions\n\n" +
                lines(recipe.directions).mapIndexed { i, step -> "${i + 1}. $step" }.joinToString("\n")
        )
        return parts.joinToString("\n\n")
    }

    fun tags(publishedAt: Long): List<List<String>> {
        val trimmedTitle = title.trim()
        val tags = mutableListOf(listOf("d", identifier), listOf("title", trimmedTitle))
        summary.trim().takeIf { it.isNotEmpty() }?.let { tags.add(listOf("summary", it)) }
        imageUrl?.let { tags.add(listOf("image", it)) }
        tags.add(listOf("published_at", publishedAt.toString()))
        val topics = mutableListOf<String>()
        if (recipe != null) {
            topics.add("zapcooking")
            topics.add("nostrcooking")
            recipe.categories.split(",").map { slug(it) }.filter { it != "post" }
                .forEach { topics.add("zapcooking-$it") }
        }
        topics.addAll(NoteTagging.hashtagTags("$trimmedTitle $body").map { it[1] })
        topics.distinct().forEach { tags.add(listOf("t", it)) }
        return tags
    }

    companion object {
        const val KIND = 30023

        fun slug(text: String): String {
            val out = StringBuilder()
            var lastWasDash = false
            for (ch in text.trim().lowercase()) {
                if (ch.isLetterOrDigit()) {
                    out.append(ch)
                    lastWasDash = false
                } else if (!lastWasDash && out.isNotEmpty()) {
                    out.append('-')
                    lastWasDash = true
                }
            }
            val s = out.toString().trimEnd('-').take(60)
            return s.ifEmpty { "post" }
        }

        /** Non-empty lines, with pasted bullets or step numbers taken off. */
        fun lines(text: String): List<String> =
            text.split("\n")
                .map { line ->
                    var l = line.trim()
                    if (l.firstOrNull()?.let { it in "-*•" } == true) l = l.drop(1)
                    Regex("^\\d+[.)]").find(l)?.let { l = l.substring(it.value.length) }
                    l.trim()
                }
                .filter { it.isNotEmpty() }
    }
}
