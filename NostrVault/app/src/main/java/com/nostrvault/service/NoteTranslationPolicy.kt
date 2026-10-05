package com.nostrvault.service

/**
 * The pure rules behind "Translate post": which notes get the button, which
 * language they translate into, and what the Settings picker offers. No ML Kit
 * in here, so it runs in a plain JVM test; [NoteTranslator] does the on-device
 * work.
 */
object NoteTranslationPolicy {

    /**
     * Letters a note needs, once links, nostr: references, hashtags and
     * @mentions are gone, before its language is worth asking about. Same
     * bar as the Global feed's language filter.
     */
    const val MINIMUM_LETTERS = FeedLanguageDetector.MINIMUM_LETTERS

    /** Fallback target when the device language can't be translated into. */
    const val FALLBACK_TARGET = "en"

    /** The note text that is language: [FeedLanguageDetector.prose]. */
    fun languageText(content: String): String = FeedLanguageDetector.prose(content)

    /** Letters in [text], counted by code point so CJK and emoji-heavy notes count right. */
    fun letterCount(text: String): Int {
        var letters = 0
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            i += Character.charCount(cp)
            if (Character.isLetter(cp)) letters++
        }
        return letters
    }

    /** Whether a note has enough words to identify at all. */
    fun hasEnoughText(content: String): Boolean = letterCount(languageText(content)) >= MINIMUM_LETTERS

    /**
     * The note's language, from a language-identification tag ("de",
     * "zh-Latn", "und"), as a translatable ISO 639-1 code — or null when it
     * can't be translated. Romanised tags ("ja-Latn", "zh-Latn") are null:
     * the translator would read them as the native script and garble them.
     */
    fun sourceLanguage(identifiedTag: String?, supported: Set<String>): String? {
        if (identifiedTag.isNullOrBlank()) return null
        if (identifiedTag.contains("-Latn", ignoreCase = true)) return null
        val base = FeedLanguageDetector.baseCode(identifiedTag) ?: return null
        return base.takeIf { it in supported }
    }

    /**
     * Whether to show the Translate button: the feature is on, the note has
     * enough text, its language was identified and can be translated, and it
     * is not already in the target language.
     */
    fun shouldOffer(
        enabled: Boolean,
        content: String,
        source: String?,
        target: String,
    ): Boolean = enabled && source != null && source != target && hasEnoughText(content)

    /**
     * The language notes translate into: the saved choice, or (when nothing
     * was picked, saved as "") the device's first language the translator
     * supports, or English.
     */
    fun target(saved: String, deviceTags: List<String>, supported: Set<String>): String {
        FeedLanguageDetector.baseCode(saved)?.takeIf { it in supported }?.let { return it }
        return deviceTags.firstNotNullOfOrNull { tag ->
            FeedLanguageDetector.baseCode(tag)?.takeIf { it in supported }
        } ?: FALLBACK_TARGET
    }

    /**
     * The "Translate to" choices: the device's languages first, then the
     * Global feed's language list, keeping only what the translator supports.
     */
    fun pickerList(deviceTags: List<String>, supported: Set<String>): List<String> =
        FeedLanguage.pickerList(deviceTags).map { it.code }.filter { it in supported }

    /**
     * The note text split into translatable lines. Blank lines and lines that
     * are only links, hashtags or mentions are passed through untouched, so
     * the translation keeps the note's shape and its URLs.
     */
    fun segments(plainText: String): List<Segment> =
        plainText.split('\n').map { line ->
            if (letterCount(languageText(line)) == 0) Segment(line, translate = false)
            else Segment(line, translate = true)
        }

    data class Segment(val text: String, val translate: Boolean)
}
