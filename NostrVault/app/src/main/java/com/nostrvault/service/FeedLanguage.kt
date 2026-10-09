package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import java.util.Locale

/**
 * A language the Global feed can be narrowed to. `code` is an ISO 639-1 code
 * (both Chinese scripts fold into "zh"). Port of iOS FeedLanguage.swift.
 */
data class FeedLanguage(val code: String) {

    /** Name in the reader's own locale ("German" in English, "Deutsch" in German). */
    fun displayName(locale: Locale = Locale.getDefault()): String {
        val name = Locale.forLanguageTag(code).getDisplayLanguage(locale)
        if (name.isNullOrBlank() || name == code) return code
        return name.replaceFirstChar { if (it.isLowerCase()) it.titlecase(locale) else it.toString() }
    }

    companion object {
        /**
         * The languages offered in the picker, roughly by how much of each is
         * on Nostr. Anything else can still be picked up through the device's
         * own languages. Same list as iOS.
         */
        val OFFERED: List<String> = listOf(
            "en", "es", "pt", "de", "fr", "ja", "zh", "ko", "ru", "it",
            "nl", "tr", "pl", "uk", "fa", "ar", "id", "th", "vi", "hi",
            "sv", "cs",
        )

        /**
         * The device's own languages first (BCP-47 tags, e.g. from
         * `LocaleList.getDefault()`), then the rest of [OFFERED].
         */
        fun pickerList(preferredTags: List<String>): List<FeedLanguage> {
            val preferred = preferredTags.mapNotNull { FeedLanguageDetector.baseCode(it) }
            return (preferred + OFFERED).distinct().map(::FeedLanguage)
        }

        /** "All languages", or the picked languages' names. */
        fun summary(selected: List<String>, locale: Locale = Locale.getDefault()): String =
            if (selected.isEmpty()) "All languages"
            else selected.joinToString(", ") { FeedLanguage(it).displayName(locale) }
    }
}

/**
 * Works out which language a note is written in, on device.
 *
 * iOS asks Apple's NLLanguageRecognizer. Android has no equivalent that runs
 * in a plain JVM (and the system TextClassifier differs per phone), so this
 * is a small self-contained detector: the writing system settles most
 * languages outright (Japanese kana, Hangul, Cyrillic, Arabic, Thai,
 * Devanagari...), and Latin-script text is judged by its common function
 * words ("the", "und", "que", "và"...).
 *
 * Notes too short or too mixed to call return null, and the filter keeps
 * them: an image post with a two-word caption, or one that is only links and
 * hashtags, has no language to judge, and hiding those would empty the feed
 * of pictures.
 */
object FeedLanguageDetector {
    /** Letters needed before a guess is trusted (same as iOS). */
    const val MINIMUM_LETTERS = 12

    /** Share the top guess needs: of all letters for a script, of the top two scores for words (same 0.6 as iOS). */
    const val MINIMUM_CONFIDENCE = 0.6

    /** Function-word hits a Latin-script guess needs. */
    private const val MINIMUM_WORD_SCORE = 2.0

    private val json = Json { ignoreUnknownKeys = true }

    /** "en-US" -> "en", "zh-Hant" -> "zh", "pt_BR" -> "pt". Legacy Java codes fold to their ISO ones. */
    fun baseCode(identifier: String): String? {
        val base = identifier.split('-', '_').firstOrNull()?.lowercase(Locale.ROOT)
        if (base.isNullOrEmpty() || base == "und") return null
        return when (base) {
            "iw" -> "he"
            "in" -> "id"
            "ji" -> "yi"
            else -> base
        }
    }

    /**
     * The note text with what is not language stripped: links, nostr:
     * references, hashtags, @mentions.
     */
    fun prose(content: String): String =
        content.split(Regex("\\s+"))
            .filter { word ->
                val w = word.lowercase(Locale.ROOT)
                w.isNotEmpty() && !(
                    w.startsWith("http://") || w.startsWith("https://") || w.startsWith("nostr:") ||
                        w.startsWith("#") || w.startsWith("@") || w.startsWith("npub1") || w.startsWith("note1")
                    )
            }
            .joinToString(" ")

    /**
     * The words to judge. A raw kind-6 repost carries the reposted event as
     * JSON, so it is judged by that event's text, not by the JSON.
     *
     * Unlike iOS, a kind-6 whose content is not JSON returns that content:
     * Android's FeedNote has already swapped the reposted text in, so by the
     * time a feed note reaches here its content is the reposted text.
     */
    fun text(content: String, kind: Int): String {
        if (kind != 6) return content
        val trimmed = content.trimStart()
        if (!trimmed.startsWith("{")) return content
        return try {
            json.decodeFromString<JsonObject>(trimmed)["content"]?.jsonPrimitive?.contentOrNull ?: ""
        } catch (_: Exception) {
            content
        }
    }

    /** ISO 639-1 code of the note's language, or null when it can't be told. */
    fun detect(content: String): String? {
        val text = prose(content)
        val counts = IntArray(Script.entries.size)
        var letters = 0
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            i += Character.charCount(cp)
            if (!Character.isLetter(cp)) continue
            letters++
            counts[scriptOf(cp).ordinal]++
        }
        if (letters < MINIMUM_LETTERS) return null

        // Kana and Han are one script for this purpose: Japanese mixes them.
        val cjk = counts[Script.HAN.ordinal] + counts[Script.KANA.ordinal]
        val shares = Script.entries.associateWith { s ->
            when (s) {
                Script.HAN, Script.KANA -> cjk
                else -> counts[s.ordinal]
            }
        }
        val (top, topCount) = shares.maxBy { it.value }
        if (top == Script.OTHER || topCount.toDouble() / letters < MINIMUM_CONFIDENCE) return null

        return when (top) {
            Script.HAN, Script.KANA ->
                // Japanese is a third or more kana; Chinese has none. A tenth
                // allows for kanji-heavy headlines.
                if (counts[Script.KANA.ordinal] * 10 >= cjk) "ja" else "zh"
            Script.HANGUL -> "ko"
            Script.CYRILLIC -> if (text.any { it in UKRAINIAN_LETTERS }) "uk" else "ru"
            Script.ARABIC -> when {
                text.any { it in URDU_LETTERS } -> "ur"
                text.any { it in PERSIAN_LETTERS } -> "fa"
                else -> "ar"
            }
            Script.THAI -> "th"
            Script.DEVANAGARI -> "hi"
            Script.GREEK -> "el"
            Script.HEBREW -> "he"
            Script.LATIN -> detectLatin(text)
            Script.OTHER -> null
        }
    }

    /**
     * Whether a note may show when the feed is narrowed to `allowed`. An empty
     * `allowed` means no narrowing; a note whose language can't be told stays.
     */
    fun admits(detected: String?, allowed: Set<String>): Boolean {
        if (allowed.isEmpty() || detected == null) return true
        return detected in allowed
    }

    // ── Latin script: function words ────────────────────────────────

    private fun detectLatin(text: String): String? {
        val words = text.lowercase(Locale.ROOT)
            .split(Regex("[^\\p{L}]+"))
            .filter { it.isNotEmpty() }
        if (words.isEmpty()) return null
        val scores = HashMap<String, Double>()
        for (word in words) {
            // One-letter words ("i", "e", "o", "y") are shared by too many
            // languages to count fully.
            val weight = if (word.length == 1) 0.5 else 1.0
            for ((code, set) in FUNCTION_WORDS) {
                if (word in set) scores[code] = (scores[code] ?: 0.0) + weight
            }
        }
        val ranked = scores.entries.sortedByDescending { it.value }
        val best = ranked.firstOrNull() ?: return null
        if (best.value < MINIMUM_WORD_SCORE) return null
        val runnerUp = ranked.getOrNull(1)?.value ?: 0.0
        if (best.value / (best.value + runnerUp) < MINIMUM_CONFIDENCE) return null
        return best.key
    }

    // ── Scripts ─────────────────────────────────────────────────────

    private enum class Script { LATIN, HAN, KANA, HANGUL, CYRILLIC, ARABIC, THAI, DEVANAGARI, GREEK, HEBREW, OTHER }

    private fun scriptOf(cp: Int): Script = when (Character.UnicodeScript.of(cp)) {
        Character.UnicodeScript.LATIN -> Script.LATIN
        Character.UnicodeScript.HAN -> Script.HAN
        Character.UnicodeScript.HIRAGANA, Character.UnicodeScript.KATAKANA -> Script.KANA
        Character.UnicodeScript.HANGUL -> Script.HANGUL
        Character.UnicodeScript.CYRILLIC -> Script.CYRILLIC
        Character.UnicodeScript.ARABIC -> Script.ARABIC
        Character.UnicodeScript.THAI -> Script.THAI
        Character.UnicodeScript.DEVANAGARI -> Script.DEVANAGARI
        Character.UnicodeScript.GREEK -> Script.GREEK
        Character.UnicodeScript.HEBREW -> Script.HEBREW
        // The long-vowel mark ー is COMMON but a letter; count it as kana.
        else -> if (cp == 0x30FC) Script.KANA else Script.OTHER
    }

    /** Letters Ukrainian has and Russian does not. */
    private val UKRAINIAN_LETTERS = setOf('і', 'ї', 'є', 'ґ', 'І', 'Ї', 'Є', 'Ґ')

    /** Letters Persian adds to the Arabic alphabet (پ چ ژ گ, and its own ک ی). */
    private val PERSIAN_LETTERS = setOf('پ', 'چ', 'ژ', 'گ', 'ک', 'ی')

    /** Letters only Urdu uses (ٹ ڈ ڑ ں ے ہ). */
    private val URDU_LETTERS = setOf('ٹ', 'ڈ', 'ڑ', 'ں', 'ے', 'ہ')

    /**
     * Common function words per Latin-script language. Words shared between
     * languages are fine: the confidence rule needs the top language to beat
     * the runner-up, so "de" or "la" alone never decides anything.
     */
    private val FUNCTION_WORDS: Map<String, Set<String>> = mapOf(
        "en" to words(
            "the and is are was were of to in that this it for with you not have has had be been " +
                "my your what when but they we just all so do does did from about will would can could " +
                "there their an at if or me he she out up how get like more every one some them who which " +
                "than then only also very much our us his her its these those because after before over " +
                "any new should see need make going want think know people good time today really here now " +
                "morning everyone thank thanks don",
        ),
        "es" to words(
            "el la los las de que y en del por para con una uno es está están son pero como más muy hoy " +
                "todo todos todas yo hay este esta eso esto mi tu su sus se lo al nos ya cuando también " +
                "porque qué cómo día días bien sin sobre buenos buenas gracias vamos hacer tiene tengo " +
                "ser soy eres fue nada algo aquí ahora siempre",
        ),
        "pt" to words(
            "o os as um uma do da dos das no na nos nas em e é não que com para por mais mas como eu você " +
                "ele ela isso isto este esta está estou meu minha seu sua hoje muito também porque já ao aos " +
                "pelo pela são foi ser ter tem bom boa dia pessoal vou obrigado obrigada aqui agora sempre " +
                "nada algo então",
        ),
        "de" to words(
            "der die das und ist ich nicht ein eine einen einem zu mit den dem des auf für von sich auch es " +
                "sie wir du er im sind war aber wenn noch nur wie was hat haben heute ja nein mehr schon kann " +
                "morgen guten tag zusammen bei aus nach oder mein dein gut dass sehr hier jetzt immer alle " +
                "werden wird",
        ),
        "fr" to words(
            "le la les des du de et est un une je tu il elle nous vous ils pas ne que qui pour dans sur avec " +
                "ce cette ces mais ou où plus très au aux son sa ses mon ma mes être avoir fait bonjour tout " +
                "tous comme bien aujourd hui merci ici maintenant toujours rien suis sont",
        ),
        "it" to words(
            "il lo la gli le di del della che e è un una per con non sono ho ha mi ti si ma come anche più " +
                "questo questa oggi tutti tutto molto nel nella alla al dei delle sul ci io buongiorno perché " +
                "cosa essere fatto grazie qui adesso sempre niente",
        ),
        "nl" to words(
            "de het een en van is dat die niet op te met voor zijn ik je we wij maar ook er als om aan bij " +
                "naar dan nog wat hoe heb hebben was wordt worden deze dit goed vandaag goedemorgen geen meer " +
                "heel allemaal kan zo of hier nu altijd bedankt",
        ),
        "sv" to words(
            "och att det som en är på för med inte jag du vi de av till har den ett om men så kan var från " +
                "nu här idag alla mycket eller sig hur vad god morgon bra tack också",
        ),
        "tr" to words(
            "ve bir bu da de ile için çok ne ama gibi daha ben sen o biz var yok değil mi mı mu mü olarak olan " +
                "ki her şey kadar sonra günaydın bugün nasıl neden iyi teşekkürler",
        ),
        "pl" to words(
            "i w z na się nie to jest że do o jak ale co tak po za od dla czy już tylko jestem mnie mi ten ta " +
                "są być był była dzień dobry wszystkim dziś dzisiaj bardzo jeszcze może dziękuję",
        ),
        "cs" to words(
            "je se na v že to s z do pro jak ale jsem jsou není by už jen tak co mi ten ta být byl dnes všem " +
                "dobré ráno velmi také když nebo ještě který která děkuji",
        ),
        "id" to words(
            "yang dan di ini itu dengan untuk tidak ada dari ke akan saya kita kami aku kamu juga sudah bisa " +
                "pada atau karena jadi hari selamat pagi semua sangat lebih apa mau sekali belum orang terima kasih",
        ),
        "vi" to words(
            "và của là không có người những được cho này một các trong với đã để tôi bạn chúng ta khi thì " +
                "rất cũng như đến ngày hôm nay chào mọi cảm ơn",
        ),
    )

    private fun words(list: String): Set<String> = list.split(' ').filter { it.isNotEmpty() }.toSet()
}
