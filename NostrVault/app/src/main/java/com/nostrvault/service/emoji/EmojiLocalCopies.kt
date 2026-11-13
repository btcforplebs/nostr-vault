package com.nostrvault.service.emoji

import com.nostrvault.fips.EmojiNote
import com.nostrvault.service.CustomEmoji
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File

/**
 * Emoji link → the vault's own copy of the image, for every custom emoji drawn anywhere (feed, picker, reactions):
 * the copy first, the link only when this device has none (plan §4.2 "Show local first"). Filled by [EmojiVaultStore];
 * read from composables, so a plain object.
 */
object EmojiLocalCopies {
    private val _byUrl = MutableStateFlow<Map<String, File>>(emptyMap())
    val byUrl: StateFlow<Map<String, File>> = _byUrl.asStateFlow()

    /** What [CustomEmojiImage] loads for [emoji]: the vault file when there is one, else its link. */
    fun model(emoji: CustomEmoji): Any = _byUrl.value[emoji.url] ?: emoji.url

    /** The vault folder is listed once, not per emoji. */
    internal fun update(saved: Collection<EmojiVaultStore.Saved>, notes: List<EmojiNote>, vaultDir: File?) {
        val files = vaultDir?.listFiles()?.filter { it.isFile }.orEmpty()
            .associateBy { it.name.substringBefore('.').lowercase() }
        _byUrl.value = urlMap(saved.map { it.sha256 to it.codes } + notes.map { it.sha256 to it.codes }) { files[it] }
    }

    /** Pure: each code's url → the first hash for it that has a file. */
    internal fun urlMap(pairs: List<Pair<String, List<List<String>>>>, fileFor: (String) -> File?): Map<String, File> = buildMap {
        for ((sha, codes) in pairs) {
            val f = fileFor(sha) ?: continue
            for (c in codes) if (c.size >= 2) putIfAbsent(c[1], f)
        }
    }
}
