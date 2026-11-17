package com.nostrvault.service

import android.content.Context
import android.icu.text.Transliterator
import android.util.Log
import android.util.LruCache
import com.nostrvault.service.translate.BergamotNative
import com.nostrvault.service.translate.LanguageIdentifier
import com.nostrvault.service.translate.TranslationLanguages
import com.nostrvault.service.translate.TranslationModelStore
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

/**
 * "Translate post", on device, with Mozilla's Bergamot engine (Firefox
 * Translations) and fastText language ID; no Google code. Language ID
 * (bundled model) decides whether a note gets the button; translation
 * downloads Mozilla's model for each direction the first time it is needed
 * ([TranslationModelStore]). Nothing else leaves the phone — the note text
 * never does.
 *
 * Results are cached in memory per note (language) and per note + target
 * (translation), so scrolling back to a note neither re-identifies nor
 * re-translates it. The work runs in this singleton's own scope, not the
 * card's: a card scrolled away mid-translation still fills the cache, and
 * the next card to ask joins the same job instead of starting another.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@Singleton
class NoteTranslator @Inject constructor(
    @ApplicationContext context: Context,
    private val models: TranslationModelStore,
) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /**
     * Two lanes, each one native call at a time: language ID for the feed's
     * buttons never waits behind a translation, and Bergamot's service is
     * single-threaded.
     */
    private val idLane = Dispatchers.Default.limitedParallelism(1)
    private val translateLane = Dispatchers.Default.limitedParallelism(1)

    private val identifier = LanguageIdentifier(context)

    /** ISO 639-1 codes Mozilla can translate between; empty when the engine is missing. */
    val supportedLanguages: Set<String> by lazy {
        if (BergamotNative.isAvailable) TranslationLanguages.SUPPORTED else emptySet()
    }

    /** Note key -> translatable source language, or [UNKNOWN]. */
    private val languages = LruCache<String, String>(2_000)
    private val identifying = ConcurrentHashMap<String, Deferred<String?>>()

    /** "noteKey|target" -> translated text. */
    private val translations = LruCache<String, String>(300)
    private val translating = ConcurrentHashMap<String, Deferred<String>>()

    // Touched only on [translateLane].
    /** Loaded Bergamot models by config; two cover a pivot, the oldest is freed. */
    private val loaded = object : LinkedHashMap<String, Long>(4, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Long>): Boolean {
            if (size <= MAX_LOADED_MODELS) return false
            BergamotNative.freeModel(eldest.value)
            return true
        }
    }

    /** True once [noteKey] has been identified (the answer may still be null). */
    fun isIdentified(noteKey: String): Boolean = languages.get(noteKey) != null

    /** The cached source language of [noteKey]; null when unknown or not identified yet. */
    fun cachedLanguage(noteKey: String): String? = languages.get(noteKey)?.takeIf { it != UNKNOWN }

    /** The cached translation of [noteKey] into [target], if there is one. */
    fun cachedTranslation(noteKey: String, target: String): String? = translations.get("$noteKey|$target")

    /**
     * The translatable language [text] is written in, or null when it can't
     * be told or can't be translated. [text] should already be the note's
     * prose ([NoteTranslationPolicy.languageText]).
     */
    suspend fun identify(noteKey: String, text: String): String? {
        languages.get(noteKey)?.let { return it.takeIf { code -> code != UNKNOWN } }
        val job = identifying.computeIfAbsent(noteKey) {
            // Lazy: started by await() below, after the map holds it, so the
            // finally's remove() can never run before the put.
            scope.async(start = CoroutineStart.LAZY) {
                try {
                    val guess = withContext(idLane) {
                        runCatching { identifier.identify(text) }
                            .onFailure { Log.w(TAG, "identify failed", it) }
                            .getOrNull()
                    }
                    val code = guess?.takeIf { it.probability >= CONFIDENCE }
                        ?.let { TranslationLanguages.fromLanguageId(it.label) }
                    val source = NoteTranslationPolicy.sourceLanguage(code, supportedLanguages)
                    languages.put(noteKey, source ?: UNKNOWN)
                    source
                } finally {
                    identifying.remove(noteKey)
                }
            }
        }
        return job.await()
    }

    /** Whether translating [source] to [target] has to download a model first. */
    suspend fun needsDownload(source: String, target: String): Boolean = withContext(Dispatchers.IO) {
        steps(source, target, sourceText = null).any { (from, to) -> models.installed(from, to) == null }
    }

    /**
     * [plainText] translated from [source] into [target], line by line so the
     * note keeps its breaks; lines that are only links or hashtags are kept as
     * they are. Downloads the language models from Mozilla on first use, on
     * any network.
     */
    suspend fun translate(noteKey: String, plainText: String, source: String, target: String): String {
        val cacheKey = "$noteKey|$target"
        translations.get(cacheKey)?.let { return it }
        val job = translating.computeIfAbsent(cacheKey) {
            // Lazy: started by await() below, after the map holds it, so the
            // finally's remove() can never run before the put.
            scope.async(start = CoroutineStart.LAZY) {
                try {
                    val installed = steps(source, target, plainText).map { (from, to) -> models.ensure(from, to) }
                    val segments = NoteTranslationPolicy.segments(plainText)
                    val inputs = segments.filter { it.translate }.map { it.text }.toTypedArray()
                    val outputs = if (inputs.isEmpty()) emptyArray() else withContext(translateLane) {
                        val handles = installed.map { loadModel(it.bergamotConfig()) }
                        val svc = BergamotNative.service
                        when (handles.size) {
                            1 -> BergamotNative.translate(svc, handles[0], inputs)
                            2 -> BergamotNative.pivot(svc, handles[0], handles[1], inputs)
                            else -> inputs
                        }
                    }
                    var next = 0
                    val out = segments.joinToString("\n") { segment ->
                        if (segment.translate) outputs.getOrElse(next++) { segment.text } else segment.text
                    }
                    translations.put(cacheKey, out)
                    out
                } finally {
                    translating.remove(cacheKey)
                }
            }
        }
        return job.await()
    }

    private fun loadModel(config: String): Long {
        loaded[config]?.let { return it }
        val handle = BergamotNative.loadModel(config)
        loaded[config] = handle
        return handle
    }

    /**
     * The Mozilla directions for [source] -> [target]. Chinese picks its
     * script: a note's own (Traditional when converting it to Simplified
     * changes it), and the reader's from the device locale.
     */
    private fun steps(source: String, target: String, sourceText: String?): List<Pair<String, String>> =
        TranslationLanguages.plan(source, target).map { (from, to) ->
            TranslationLanguages.mozillaCode(from, traditionalChinese = from == source && isTraditional(sourceText)) to
                TranslationLanguages.mozillaCode(to, traditionalChinese = to == target && deviceReadsTraditional())
        }

    private fun isTraditional(text: String?): Boolean {
        if (text.isNullOrEmpty()) return false
        return runCatching { Transliterator.getInstance("Hant-Hans").transliterate(text) != text }.getOrDefault(false)
    }

    private fun deviceReadsTraditional(): Boolean {
        val locale = Locale.getDefault()
        if (locale.language != "zh") return false
        return locale.script == "Hant" || locale.country in setOf("TW", "HK", "MO")
    }

    private companion object {
        const val TAG = "NoteTranslator"
        const val UNKNOWN = ""

        /** Below this fastText's guess is not trusted and the note gets no button. */
        const val CONFIDENCE = 0.5

        const val MAX_LOADED_MODELS = 2
    }
}
