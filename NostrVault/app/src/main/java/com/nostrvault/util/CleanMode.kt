package com.nostrvault.util

import android.content.Context
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Clean mode (Logen 2026-11-27): a local setting, off by default and never
 * published, that shows a word from the built-in list as its first letter
 * plus asterisks, same length, case kept (`Fuck` → `F***`). Whole words only,
 * case-insensitive, so `ass` never masks `class`. It changes only what is
 * shown: note text, bios, profile and display names, DMs, link previews and
 * notifications. Never the composer, drafts, what is sent or signed, search
 * queries or stored events.
 *
 * The list is `docs/clean-words/en.txt`, copied to `assets/clean-words-en.txt`
 * (docs/clean-words/check.sh keeps them the same). iOS: CleanMode.swift;
 * web: net/clean-mode.js.
 */
object CleanMode {
    const val ASSET = "clean-words-en.txt"

    /**
     * Snapshot state, so a screen that showed text through [shown] (or a
     * name through FeedProfile.bestName) redraws when the setting changes.
     */
    var enabled by mutableStateOf(false)

    @Volatile private var words: Set<String> = emptySet()

    /** A run of letters and digits: a word, with its boundaries. */
    private val WORD = Regex("[\\p{L}\\p{N}]+")

    /** Reads the built-in list once, off the main thread. */
    fun load(context: Context) {
        words = runCatching {
            context.assets.open(ASSET).bufferedReader().useLines { parse(it.toList()) }
        }.onFailure { Log.w("CleanMode", "word list not read: ${it.message}") }.getOrDefault(emptySet())
    }

    /** The list's words: one lowercase word per line. */
    fun parse(lines: List<String>): Set<String> =
        lines.map { it.trim().lowercase() }.filter { it.isNotEmpty() }.toSet()

    /** [text] as shown: masked while clean mode is on. */
    fun shown(text: String): String {
        if (!enabled) return text
        val list = words
        return if (list.isEmpty()) text else mask(text, list)
    }

    /** [text] with each whole word on [list] masked, first letter kept. */
    fun mask(text: String, list: Set<String>): String {
        if (text.isEmpty() || list.isEmpty()) return text
        var changed = false
        val out = WORD.replace(text) { m ->
            val w = m.value
            if (w.lowercase() in list) {
                changed = true
                w.substring(0, w.offsetByCodePoints(0, 1)) + "*".repeat(w.codePointCount(0, w.length) - 1)
            } else w
        }
        return if (changed) out else text
    }
}
