package com.nostrvault.ui.screens.live

import android.content.Context
import android.net.Uri
import com.nostrvault.service.BlossomService
import com.nostrvault.service.MediaPrivacy
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * A photo, video or GIF from the phone, put on the user's media servers for a
 * chat line: this device's relay first, then the outside Blossom servers, as a
 * note attachment is (BlossomService.uploadForPost). The location comes out
 * before the hash, because the blob is public once it is up.
 *
 * Chat lines are sent at once and never queued, so only an outside server's
 * URL will do: a blob that only reached this phone is reported, not sent.
 */
@Singleton
class LiveChatMediaUpload @Inject constructor(
    @ApplicationContext private val context: Context,
    private val blossomService: BlossomService,
) {
    sealed class Outcome {
        data class Hosted(val url: String) : Outcome()
        data class Failed(val message: String) : Outcome()
    }

    /**
     * [mimeType] is for a file the app made itself (a downloaded GIF): a
     * `file://` URI has no type the content resolver can tell.
     */
    suspend fun upload(uri: Uri, mimeType: String? = null): Outcome = withContext(Dispatchers.IO) {
        val mime = mimeType ?: context.contentResolver.getType(uri) ?: "application/octet-stream"
        val temp = File.createTempFile("livechat_", ".tmp", context.cacheDir)
        try {
            val input = context.contentResolver.openInputStream(uri)
                ?: return@withContext Outcome.Failed("Couldn't read that file.")
            input.use { i -> temp.outputStream().use { i.copyTo(it) } }
            if (!MediaPrivacy.removeLocation(temp, mime)) return@withContext Outcome.Failed(MediaPrivacy.FAILURE_MESSAGE)
            val sha256 = blossomService.computeSHA256(temp)
            when (val outcome = blossomService.uploadForPost(temp, sha256, mime)) {
                is BlossomService.PostUploadOutcome.Hosted -> Outcome.Hosted(outcome.url)
                is BlossomService.PostUploadOutcome.SavedOnDevice ->
                    Outcome.Failed("Saved on this phone, but none of your media servers answered, so it wasn't sent.")
                BlossomService.PostUploadOutcome.NoOutsideServer ->
                    Outcome.Failed("No media server is set up. Add one in Settings → Media Servers.")
                BlossomService.PostUploadOutcome.NotSavedOnDevice ->
                    Outcome.Failed("Couldn't upload that. Try again in a moment.")
            }
        } catch (e: Exception) {
            Outcome.Failed("Couldn't upload that: ${e.message ?: "unknown error"}")
        } finally {
            temp.delete()
        }
    }
}
