package com.nostrvault.data.local

import android.content.Context
import androidx.core.graphics.PaintCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Every Unicode emoji the picker offers, with its name so search works.
 * Read from `assets/emoji/emoji.tsv`, built from Unicode's emoji-test.txt
 * by `tools/gen_emoji_tsv.py`.
 */
data class EmojiCatalog(val groups: List<Group>) {
    data class Entry(val emoji: String, val name: String)
    data class Group(val name: String, val entries: List<Entry>)

    /** Every entry's name by its emoji, for search. */
    val names: Map<String, String> by lazy {
        groups.flatMap { it.entries }.associate { it.emoji to it.name }
    }

    companion object {
        const val ASSET = "emoji/emoji.tsv"

        /**
         * Reads the tsv: `# group: <name>` starts a group, `<emoji>\t<name>`
         * is one emoji. Emoji [canDraw] rejects are left out, so a phone whose
         * font predates an emoji never shows an empty box.
         */
        fun parse(text: String, canDraw: (String) -> Boolean = { true }): EmojiCatalog {
            val groups = mutableListOf<Group>()
            var name: String? = null
            var entries = mutableListOf<Entry>()
            fun close() {
                val n = name ?: return
                if (entries.isNotEmpty()) groups += Group(n, entries)
            }
            for (line in text.lineSequence()) {
                if (line.startsWith("# group:")) {
                    close()
                    name = line.removePrefix("# group:").trim()
                    entries = mutableListOf()
                } else if (line.isNotBlank() && !line.startsWith("#")) {
                    val tab = line.indexOf('\t')
                    if (tab <= 0 || name == null) continue
                    val emoji = line.substring(0, tab)
                    if (canDraw(emoji)) entries += Entry(emoji, line.substring(tab + 1).trim())
                }
            }
            close()
            return EmojiCatalog(groups)
        }

        private val lock = Mutex()
        @Volatile private var cached: EmojiCatalog? = null

        /** The catalog, read once per process off the main thread. */
        suspend fun load(context: Context): EmojiCatalog {
            cached?.let { return it }
            return lock.withLock {
                cached ?: withContext(Dispatchers.IO) {
                    val text = context.applicationContext.assets.open(ASSET).bufferedReader().use { it.readText() }
                    val paint = android.graphics.Paint()
                    parse(text) { PaintCompat.hasGlyph(paint, it) }
                }.also { cached = it }
            }
        }
    }
}
