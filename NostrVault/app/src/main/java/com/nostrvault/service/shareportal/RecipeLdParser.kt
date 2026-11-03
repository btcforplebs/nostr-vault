package com.nostrvault.service.shareportal

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull

/**
 * A page's JSON-LD Recipe → recipe draft fields (contract §6.2). Pure.
 * Twin: RecipeLdParser.swift.
 */
object RecipeLdParser {
    data class Recipe(
        val title: String = "",
        val summary: String = "",
        val prepTime: String = "",
        val cookTime: String = "",
        val servings: String = "",
        val ingredients: String = "",
        val directions: String = "",
        val categories: String = "",
        val body: String = "",
    )

    fun parse(html: String, pageTitle: String?, url: String?): Recipe {
        val r = ShareLd.find(html, "Recipe")
        if (r == null) {
            val t = pageTitle?.trim().orEmpty()
            val label = t.ifEmpty { url?.let(ArticleClipDraft::host).orEmpty() }
            return Recipe(title = t, body = ArticleClipDraft.sourceLine(label, url).orEmpty())
        }
        val name = ShareLd.string(r["name"])?.let(ShareLd::clean) ?: pageTitle?.trim().orEmpty()
        val seen = mutableSetOf<String>()
        val cats = (ShareLd.strings(r["recipeCategory"]) + ShareLd.strings(r["recipeCuisine"]))
            .flatMap { it.split(",") }
            .map(ShareLd::clean)
            .filter { it.isNotEmpty() && seen.add(it.lowercase()) }
        return Recipe(
            title = name,
            summary = ShareLd.string(r["description"])?.let(ShareLd::clean).orEmpty(),
            prepTime = ShareLd.string(r["prepTime"])?.let(::duration).orEmpty(),
            cookTime = ShareLd.string(r["cookTime"])?.let(::duration).orEmpty(),
            servings = servings(r["recipeYield"]),
            ingredients = ShareLd.strings(r["recipeIngredient"]).map(ShareLd::clean).filter { it.isNotEmpty() }.joinToString("\n"),
            directions = steps(r["recipeInstructions"]).joinToString("\n"),
            categories = cats.joinToString(", "),
            body = ArticleClipDraft.sourceLine(name, url).orEmpty(),
        )
    }

    private val durationRegex = Regex("P(?:(\\d+)D)?(?:T(?:(\\d+)H)?(?:(\\d+)M)?(?:(\\d+(?:\\.\\d+)?)S)?)?")

    /** `PT1H30M` → `1 h 30 min`; anything that isn't a whole-number duration is kept, trimmed. */
    fun duration(s: String): String {
        val t = s.trim()
        val m = durationRegex.matchEntire(t)
        if (m == null || t == "P" || t == "PT") return t
        val (d, h, mi) = m.destructured
        val hours = (d.toIntOrNull() ?: 0) * 24 + (h.toIntOrNull() ?: 0)
        val mins = mi.toIntOrNull() ?: 0
        return buildList {
            if (hours > 0) add("$hours h")
            if (mins > 0) add("$mins min")
        }.joinToString(" ")
    }

    private fun servings(e: JsonElement?): String {
        val y = if (e is JsonArray) e.firstOrNull() else e
        val p = y as? JsonPrimitive ?: return ""
        if (p.isString) return ShareLd.clean(p.content)
        val n = p.doubleOrNull ?: return ""
        return if (n == Math.floor(n) && !n.isInfinite()) n.toLong().toString() else n.toString()
    }

    private fun steps(e: JsonElement?): List<String> {
        ShareLd.string(e)?.let { s -> return s.split("\n").map(ShareLd::clean).filter { it.isNotEmpty() } }
        val list = when (e) {
            is JsonObject -> listOf(e)
            is JsonArray -> e.toList()
            else -> return emptyList()
        }
        val out = mutableListOf<String>()
        for (x in list) {
            val s = ShareLd.string(x)
            if (s != null) {
                ShareLd.clean(s).takeIf { it.isNotEmpty() }?.let(out::add)
            } else if (x is JsonObject) {
                if ("HowToSection" in ShareLd.types(x)) {
                    out += steps(x["itemListElement"] ?: JsonArray(emptyList()))
                } else {
                    val t = ShareLd.string(x["text"]) ?: ShareLd.string(x["name"]) ?: ""
                    ShareLd.clean(t).takeIf { it.isNotEmpty() }?.let(out::add)
                }
            }
        }
        return out
    }
}
