package com.nostrvault.ui.screens

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.BlobDescriptor
import com.nostrvault.service.BlossomService
import com.nostrvault.service.FileType
import com.nostrvault.service.NostrService
import com.nostrvault.service.StatsService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * What the relay's Blossom media picker lists. Shared by the post composer
 * and the live stream chat (iOS `ComposeView.relayBlossomMedia`, #307).
 */
@Singleton
class BlossomPickerMedia @Inject constructor(
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
    private val blossomService: BlossomService,
    private val statsService: StatsService,
) {
    /**
     * The owner's media for the relay picker, newest first. Each item's
     * `displayUrl` is the URL a post publishes, preferring an outside mirror so
     * the link works for readers; `localFile` is set when the blob is also on
     * this device.
     */
    suspend fun load(): List<BlossomMediaItem> = withContext(Dispatchers.IO) {
        try {
            val config = configStore.config.value
            val pubkey = nostrService.ownerHexPubkey
            val localBase = blossomService.localBlossomURL()
            // Prefer an external mirror so the published URL is publicly accessible
            val externalBase = config.activeBlossomMirrors
                .firstOrNull { url -> !url.contains("localhost") && !url.contains("127.0.0.1") }

            // Dedupe across local files, the local relay, and external mirrors by sha256.
            val items = linkedMapOf<String, BlossomMediaItem>()

            fun isHash(s: String) = s.length == 64 && s.all { it in "0123456789abcdef" }

            // Use external mirror URL (BUD-01: {server}/{sha256}) so links work in published notes;
            // fall back to the blob's own URL, then the local relay.
            fun publishUrl(sha256: String, fallbackUrl: String?): String? = when {
                externalBase != null -> "$externalBase/$sha256"
                fallbackUrl != null -> fallbackUrl
                localBase != null -> "$localBase/$sha256"
                else -> null
            }

            // 1. Files cached in the local relay's blossom directory.
            val blossomDir = config.relayDataDir?.let { File(it, config.blossomPath) }
            if (blossomDir != null && blossomDir.exists()) {
                blossomDir.listFiles()?.forEach { file ->
                    if (!file.isFile) return@forEach
                    val sha = file.nameWithoutExtension
                    if (!isHash(sha)) return@forEach
                    val kind = blobMimeType(null, file.name) ?: when (statsService.detectFileType(file)) {
                        FileType.IMAGE -> "image"
                        FileType.VIDEO -> "video"
                        else -> return@forEach
                    }
                    val url = publishUrl(sha, localBase?.let { "$it/${file.name}" }) ?: return@forEach
                    items[sha] = BlossomMediaItem(
                        sha256 = sha,
                        displayUrl = url,
                        localFile = file,
                        mimeType = kind,
                        size = file.length(),
                        uploaded = null,
                        lastModified = file.lastModified(),
                        isLocal = true,
                    )
                }
            }

            // 2. The local relay + external mirrors via the Blossom /list/<pubkey> endpoint,
            //    so media that lives only on a mirror still appears in the picker.
            if (pubkey.isNotEmpty()) {
                val sources = buildList {
                    add(null) // local relay (default nostrURL base)
                    addAll(config.activeBlossomMirrors)
                }
                val blobLists = coroutineScope {
                    sources.map { base ->
                        async {
                            try {
                                if (base == null) statsService.fetchBlobList(pubkey)
                                else statsService.fetchBlobList(pubkey, base)
                            } catch (e: Exception) {
                                emptyList<BlobDescriptor>()
                            }
                        }
                    }.awaitAll()
                }
                blobLists.flatten().forEach { blob ->
                    val sha = blob.sha256?.lowercase() ?: return@forEach
                    if (!isHash(sha)) return@forEach
                    val existing = items[sha]
                    if (existing != null) {
                        // A server knows the real type and upload time; the local file doesn't.
                        items[sha] = existing.copy(
                            mimeType = blob.type?.takeIf { '/' in it } ?: existing.mimeType,
                            uploaded = blob.uploaded ?: existing.uploaded,
                        )
                        return@forEach
                    }
                    val url = publishUrl(sha, blob.url) ?: return@forEach
                    items[sha] = BlossomMediaItem(
                        sha256 = sha,
                        displayUrl = url,
                        localFile = null,
                        mimeType = blob.type ?: blobMimeType(null, blob.url),
                        size = blob.size,
                        uploaded = blob.uploaded,
                        lastModified = null,
                        isLocal = false,
                    )
                }
            }

            // The composer attaches photos and videos only.
            items.values
                .filter { it.isImage || it.isVideo }
                .sortedByDescending { it.sortTime }
        } catch (e: Exception) {
            Log.e("BlossomPickerMedia", "Failed to load blossom media items", e)
            emptyList()
        }
    }
}
