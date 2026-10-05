package com.nostrvault.service

import android.util.Log
import android.util.LruCache
import com.google.android.gms.tasks.Task
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.nl.languageid.LanguageIdentification
import com.google.mlkit.nl.languageid.LanguageIdentificationOptions
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.TranslateRemoteModel
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * "Translate post", on device, with Google ML Kit: language identification
 * (bundled model) decides whether a note gets the button, and the translator
 * downloads one model per language the first time it is needed. Nothing else
 * leaves the phone — the note text never does.
 *
 * Results are cached in memory per note (language) and per note + target
 * (translation), so scrolling back to a note neither re-identifies nor
 * re-translates it. The work runs in this singleton's own scope, not the
 * card's: a card scrolled away mid-translation still fills the cache, and
 * the next card to ask joins the same job instead of starting another.
 */
@Singleton
class NoteTranslator @Inject constructor() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** ISO 639-1 codes ML Kit can translate between. */
    val supportedLanguages: Set<String> by lazy { TranslateLanguage.getAllLanguages().toSet() }

    private val identifier by lazy {
        LanguageIdentification.getClient(
            LanguageIdentificationOptions.Builder().setConfidenceThreshold(CONFIDENCE).build(),
        )
    }

    /** Note key -> translatable source language, or [UNKNOWN]. */
    private val languages = LruCache<String, String>(2_000)
    private val identifying = ConcurrentHashMap<String, Deferred<String?>>()

    /** "noteKey|target" -> translated text. */
    private val translations = LruCache<String, String>(300)
    private val translating = ConcurrentHashMap<String, Deferred<String>>()

    /** One open translator per language pair; the least recently used is closed. */
    private val translators = object : LruCache<String, Translator>(4) {
        override fun entryRemoved(evicted: Boolean, key: String, oldValue: Translator, newValue: Translator?) {
            if (oldValue !== newValue) oldValue.close()
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
                    val tag = runCatching { identifier.identifyLanguage(text).await() }
                        .onFailure { Log.w(TAG, "identify failed", it) }
                        .getOrNull()
                    val source = NoteTranslationPolicy.sourceLanguage(tag, supportedLanguages)
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
    suspend fun needsDownload(source: String, target: String): Boolean {
        val manager = RemoteModelManager.getInstance()
        return listOf(source, target).any { lang ->
            runCatching {
                !manager.isModelDownloaded(TranslateRemoteModel.Builder(lang).build()).await()
            }.getOrDefault(true)
        }
    }

    /**
     * [plainText] translated from [source] into [target], line by line so the
     * note keeps its breaks; lines that are only links or hashtags are kept as
     * they are. Downloads the language models on first use, on any network.
     */
    suspend fun translate(noteKey: String, plainText: String, source: String, target: String): String {
        val cacheKey = "$noteKey|$target"
        translations.get(cacheKey)?.let { return it }
        val job = translating.computeIfAbsent(cacheKey) {
            // Lazy: started by await() below, after the map holds it, so the
            // finally's remove() can never run before the put.
            scope.async(start = CoroutineStart.LAZY) {
                try {
                    val translator = translatorFor(source, target)
                    translator.downloadModelIfNeeded(DownloadConditions.Builder().build()).await()
                    val lines = mutableListOf<String>()
                    for (segment in NoteTranslationPolicy.segments(plainText)) {
                        lines += if (segment.translate) translator.translate(segment.text).await() else segment.text
                    }
                    val out = lines.joinToString("\n")
                    translations.put(cacheKey, out)
                    out
                } finally {
                    translating.remove(cacheKey)
                }
            }
        }
        return job.await()
    }

    private fun translatorFor(source: String, target: String): Translator = synchronized(translators) {
        val key = "$source>$target"
        translators.get(key) ?: Translation.getClient(
            TranslatorOptions.Builder()
                .setSourceLanguage(source)
                .setTargetLanguage(target)
                .build(),
        ).also { translators.put(key, it) }
    }

    private companion object {
        const val TAG = "NoteTranslator"
        const val UNKNOWN = ""

        /** ML Kit's own default: below this a note is "und" and gets no button. */
        const val CONFIDENCE = 0.5f
    }
}

/** A Play Services [Task] as a suspend call. */
private suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { cont ->
    addOnSuccessListener { cont.resume(it) }
    addOnFailureListener { cont.resumeWithException(it) }
    addOnCanceledListener { cont.cancel() }
}
