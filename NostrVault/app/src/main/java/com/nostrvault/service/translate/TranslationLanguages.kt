package com.nostrvault.service.translate

/**
 * The languages "Translate post" works with, and how a note's language maps
 * onto Mozilla's models. Mozilla ships one model per direction between
 * English and each language (Firefox Translations); any other pair goes
 * through English, two models in a row. Pure, so it runs in a JVM test.
 */
object TranslationLanguages {

    const val PIVOT = "en"

    /**
     * ISO 639-1 codes with a model both into and out of English on Mozilla's
     * server (firefox.settings.services.mozilla.com, translations-models,
     * checked 2026-11-16). "zh" stands for both Chinese scripts.
     */
    val SUPPORTED: Set<String> = setOf(
        "af", "ar", "az", "be", "bg", "bn", "bs", "ca", "cs", "da", "de", "el", "en", "es", "et",
        "eu", "fa", "fi", "fr", "gl", "gu", "he", "hi", "hr", "hu", "id", "is", "it", "ja", "kn",
        "ko", "lt", "lv", "ml", "mr", "ms", "nb", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sq",
        "sr", "sv", "ta", "te", "th", "tl", "tr", "ug", "uk", "ur", "vi", "zh",
    )

    /**
     * A fastText lid.176 label as an app language code, or null when the app
     * can't translate it. fastText says "no" for Norwegian Bokmål and "zh"
     * for both Chinese scripts.
     */
    fun fromLanguageId(label: String): String? {
        val code = when (label) {
            "no" -> "nb"
            "iw" -> "he"
            "in" -> "id"
            "fil" -> "tl"
            else -> label
        }
        return code.takeIf { it in SUPPORTED }
    }

    /** The code Mozilla files a language under: Chinese is split by script. */
    fun mozillaCode(code: String, traditionalChinese: Boolean): String =
        if (code == "zh") (if (traditionalChinese) "zh-Hant" else "zh-Hans") else code

    /**
     * The model directions [source] -> [target] needs, in the order they run:
     * one when either side is English, two through English otherwise, none
     * when the two are the same.
     */
    fun plan(source: String, target: String): List<Pair<String, String>> = when {
        source == target -> emptyList()
        source == PIVOT || target == PIVOT -> listOf(source to target)
        else -> listOf(source to PIVOT, PIVOT to target)
    }
}
