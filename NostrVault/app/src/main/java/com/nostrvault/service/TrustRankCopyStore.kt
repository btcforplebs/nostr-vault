package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.TrustRankCopy
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The phone's copy of its Haven's trust rank, one per account
 * ([TrustRankCopy]). Read from disk once and kept while the file is
 * unchanged (about 2 MB on a 28,000-person map). Null with no Haven, no file
 * yet, or a file that does not check out.
 */
@Singleton
class TrustRankCopyStore @Inject constructor(
    private val configStore: ConfigStore,
) {
    private data class Held(val path: String, val modified: Long, val length: Long, val copy: TrustRankCopy?)

    @Volatile private var held: Held? = null

    /** The active account's copy. */
    suspend fun active(): TrustRankCopy? = copyFor(configStore.activeAccountHexPubkey.value)

    suspend fun copyFor(account: String): TrustRankCopy? {
        if (account.length != 64) return null
        val dir = configStore.config.value.relayDataDir ?: return null
        return withContext(Dispatchers.IO) { read(File(dir, fileName(account)), account) }
    }

    private fun read(file: File, account: String): TrustRankCopy? {
        if (!file.isFile) return null
        val modified = file.lastModified()
        val length = file.length()
        held?.let { if (it.path == file.path && it.modified == modified && it.length == length) return it.copy }
        val copy = runCatching { TrustRankCopy.parse(file.readText(), account) }.getOrNull()
        held = Held(file.path, modified, length, copy)
        return copy
    }

    companion object {
        /** haven-go `trustrank.ResultPath`. */
        fun fileName(account: String) = "wot_rank_$account.json"
    }
}
