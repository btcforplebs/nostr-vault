package com.nostrvault.service

import kotlinx.serialization.Serializable

/**
 * NIP-30 custom emoji: an event's `["emoji", shortcode, url, setAddress?]`
 * tags name the images its `:shortcode:` text stands for. Kind 7 reactions
 * use the same tag with `:shortcode:` as their whole content.
 */
@Serializable
data class CustomEmoji(
    val shortcode: String,
    val url: String,
    /** The `30030:<pubkey>:<d>` set it came from, when the tag names one. */
    val setAddress: String? = null,
) {
    /** What goes in a note or reaction's content: `:shortcode:`. */
    val content: String get() = ":$shortcode:"

    /** The tag that makes [content] an image (NIP-30). */
    fun tag(): List<String> = if (setAddress != null) {
        listOf("emoji", shortcode, url, setAddress)
    } else {
        listOf("emoji", shortcode, url)
    }

    companion object {
        /** NIP-30 says `[A-Za-z0-9_]`; other apps also send `-`, so it is accepted too. */
        private val SHORTCODE = Regex("^[A-Za-z0-9_-]+$")
        private val IN_TEXT = Regex(":([A-Za-z0-9_-]+):")

        fun isValidShortcode(shortcode: String): Boolean = SHORTCODE.matches(shortcode)

        /** Only http(s) image addresses: no `data:`, `file:` or `javascript:`. */
        fun isValidURL(url: String): Boolean {
            val lower = url.trim().lowercase()
            return (lower.startsWith("https://") || lower.startsWith("http://")) &&
                lower.length > "https://".length && url.none { it.isWhitespace() }
        }

        /** One emoji tag, or null when it is malformed. */
        fun fromTag(tag: List<String>): CustomEmoji? {
            if (tag.size < 3 || tag[0] != "emoji") return null
            val shortcode = tag[1]
            val url = tag[2].trim()
            if (!isValidShortcode(shortcode) || !isValidURL(url)) return null
            val set = tag.getOrNull(3)?.takeIf { it.startsWith("30030:") }
            return CustomEmoji(shortcode, url, set)
        }

        /**
         * An event's emoji by shortcode. A shortcode tagged twice keeps the
         * first tag, so the same text always draws the same image.
         */
        fun fromTags(tags: List<List<String>>): Map<String, CustomEmoji> {
            val out = LinkedHashMap<String, CustomEmoji>()
            for (tag in tags) {
                val emoji = fromTag(tag) ?: continue
                out.putIfAbsent(emoji.shortcode, emoji)
            }
            return out
        }

        /**
         * The custom emoji a kind 7 reaction is: its content is exactly
         * `:shortcode:` and a tag gives that shortcode's image. Anything else
         * (Unicode, "+", a shortcode with no tag) is null.
         */
        fun forReaction(content: String, tags: List<List<String>>): CustomEmoji? {
            val trimmed = content.trim()
            val match = IN_TEXT.matchEntire(trimmed) ?: return null
            return fromTags(tags)[match.groupValues[1]]
        }

        /** [text] split into plain runs and the emoji [emojis] has images for. */
        fun segments(text: String, emojis: Map<String, CustomEmoji>): List<Segment> {
            if (emojis.isEmpty() || ':' !in text) return listOf(Segment.Text(text))
            val out = mutableListOf<Segment>()
            var last = 0
            for (match in IN_TEXT.findAll(text)) {
                val emoji = emojis[match.groupValues[1]] ?: continue
                if (match.range.first > last) out += Segment.Text(text.substring(last, match.range.first))
                out += Segment.Emoji(emoji)
                last = match.range.last + 1
            }
            if (last < text.length) out += Segment.Text(text.substring(last))
            return out
        }
    }

    sealed interface Segment {
        data class Text(val text: String) : Segment
        data class Emoji(val emoji: CustomEmoji) : Segment
    }
}
