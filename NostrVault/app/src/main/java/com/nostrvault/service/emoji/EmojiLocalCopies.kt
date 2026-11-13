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

    private var listing: Map<String, File> = emptyMap()
    private var listedDir: File? = null
    private var listedAt = 0L

    /**
     * The vault folder is listed once, not per emoji, and not on every rebuild: again only after a store ([relist]), for
     * another folder, or when a hash has no file yet and the last listing is over [RELIST_MS] old (copy v2 brings
     * another device's blobs later).
     */
    @Synchronized
    internal fun update(saved: Collection<EmojiVaultStore.Saved>, notes: List<EmojiNote>, vaultDir: File?, relist: Boolean, now: Long = System.currentTimeMillis()) {
        val pairs = saved.map { it.sha256 to it.codes } + notes.map { it.sha256 to it.codes }
        val missing = pairs.any { (sha, _) -> sha.lowercase() !in listing }
        if (relist || vaultDir != listedDir || (missing && now - listedAt > RELIST_MS)) {
            listing = vaultDir?.listFiles()?.filter { it.isFile }.orEmpty().associateBy { it.name.substringBefore('.').lowercase() }
            listedDir = vaultDir
            listedAt = now
        }
        _byUrl.value = urlMap(pairs) { listing[it.lowercase()] }
    }

    private const val RELIST_MS = 30_000L

    /** Pure: each code's url → the first hash for it that has a file. */
    internal fun urlMap(pairs: List<Pair<String, List<List<String>>>>, fileFor: (String) -> File?): Map<String, File> = buildMap {
        for ((sha, codes) in pairs) {
            val f = fileFor(sha) ?: continue
            for (c in codes) if (c.size >= 2) putIfAbsent(c[1], f)
        }
    }
}
