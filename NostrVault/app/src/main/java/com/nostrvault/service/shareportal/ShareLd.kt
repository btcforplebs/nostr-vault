package com.nostrvault.service.shareportal

import com.nostrvault.util.findAllOnce
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * JSON-LD helpers shared by the recipe and calendar parsers (contract §6.2):
 * the `<script type="application/ld+json">` blocks of a page, the first node
 * of a type, and HTML-cleaned text. Pure. Twin: ShareLd.swift.
 */
object ShareLd {
    private val json = Json { isLenient = false }
    private val blockRegex = Regex(
        "<script[^>]*type\\s*=\\s*[\"']?application/ld\\+json[\"']?[^>]*>(.*?)</script>",
        setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
    )

    fun blocks(html: String): List<String> = blockRegex.findAllOnce(html).map { it.groupValues[1] }.toList()

    /** The first object whose `@type` is (or lists) [type], walking arrays and `@graph` to depth 4. */
    fun find(html: String, type: String): JsonObject? {
        for (block in blocks(html)) {
            val root = runCatching { json.parseToJsonElement(block) }.getOrNull() ?: continue
            walk(root, type, 0)?.let { return it }
        }
        return null
    }

    private fun walk(node: JsonElement, type: String, depth: Int): JsonObject? {
        if (depth > 4) return null
        return when (node) {
            is JsonArray -> node.firstNotNullOfOrNull { walk(it, type, depth + 1) }
            is JsonObject -> when {
                type in types(node) -> node
                "@graph" in node -> walk(node.getValue("@graph"), type, depth + 1)
                else -> null
            }
            else -> null
        }
    }

    fun types(node: JsonObject): List<String> = when (val t = node["@type"]) {
        is JsonArray -> t.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
        is JsonPrimitive -> listOfNotNull(t.takeIf { it.isString }?.content)
        else -> emptyList()
    }

    /** A JSON string's value, or null for anything else. */
    fun string(e: JsonElement?): String? = (e as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    /** Strings only: one string, or the strings of a list. */
    fun strings(e: JsonElement?): List<String> = when (e) {
        is JsonArray -> e.mapNotNull(::string)
        else -> listOfNotNull(string(e))
    }

    private val tagRegex = Regex("<[^>]*>")
    private val entityRegex = Regex("&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+|#39);")
    private val spaceRegex = Regex("(?U)\\s+")
    private val named = mapOf(
        "amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "#39" to "'", "apos" to "'", "nbsp" to " ",
    )

    /** Tags removed, entities decoded, whitespace collapsed, trimmed. */
    fun clean(s: String): String {
        val noTags = tagRegex.replace(s, "")
        val decoded = entityRegex.replace(noTags) { m ->
            val e = m.groupValues[1]
            named[e] ?: when {
                e.startsWith("#x") || e.startsWith("#X") -> e.substring(2).toIntOrNull(16)?.let(::codePoint)
                e.startsWith("#") -> e.substring(1).toIntOrNull()?.let(::codePoint)
                else -> null
            } ?: m.value
        }
        return spaceRegex.replace(decoded.replace('\u00a0', ' '), " ").trim()
    }

    private fun codePoint(cp: Int): String? =
        if (cp in 0..0x10FFFF && cp !in 0xD800..0xDFFF) String(Character.toChars(cp)) else null
}
