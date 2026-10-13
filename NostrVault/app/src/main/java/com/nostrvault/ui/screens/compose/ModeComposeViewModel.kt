package com.nostrvault.ui.screens

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.net.Uri
import android.util.Log
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.draw.clip
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.model.DivinePost
import com.nostrvault.data.model.LongFormDraft
import com.nostrvault.data.model.MediaUploadOutcomeMessage
import com.nostrvault.data.model.PostingAccount
import com.nostrvault.data.model.Reel
import com.nostrvault.service.BlossomService
import com.nostrvault.service.MediaPrivacy
import com.nostrvault.service.NostrService
import com.nostrvault.service.ReelsFeedService
import com.nostrvault.ui.notification.ErrorStyle
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.ByteBuffer
import javax.inject.Inject

/** What the post button writes in feeds that show something other than notes. */
enum class ModeComposerKind(val route: String, val buttonTitle: String) {
    DIVINE("divine", "diVine"),
    ARTICLE("article", "Write"),
    RECIPE("recipe", "Recipe"),
    /** A NIP-99 listing for the Marketplace; see MarketplaceSellScreen. */
    LISTING("listing", "Sell"),
    /** A NIP-88 poll for the Polls feed; see PollComposeScreen. */
    POLL("poll", "Poll");

    companion object {
        fun fromRoute(route: String?): ModeComposerKind = entries.firstOrNull { it.route == route } ?: ARTICLE
    }
}

/** A picked or recorded video, measured and with a poster frame. */
data class PickedClip(
    val file: File,
    val poster: Bitmap,
    val width: Int,
    val height: Int,
    val durationSeconds: Double,
    val mimeType: String,
    /** The source ran past the diVine limit and was cut to its opening. */
    val wasTrimmed: Boolean = false,
    /** Degrees the source asks players to rotate it, kept when trimming. */
    val rotation: Int = 0,
)

/**
 * Publishes diVines (kind 34236) and long-form articles and recipes (kind
 * 30023). Port of the iOS DivineComposeView / LongFormComposeView.
 */
@HiltViewModel
class ModeComposeViewModel @Inject constructor(
    private val nostrService: NostrService,
    private val blossomService: BlossomService,
    private val reelsFeedService: ReelsFeedService,
    private val marketplaceFeedService: com.nostrvault.service.MarketplaceFeedService,
    private val notificationManager: NotificationManager,
    private val configStore: com.nostrvault.data.local.ConfigStore,
    internal val draftStore: ComposerDraftStore,
    @ApplicationContext private val context: Context,
    savedStateHandle: SavedStateHandle,
) : ViewModel() {
    val kind = ModeComposerKind.fromRoute(savedStateHandle["kind"])

    private val _clip = MutableStateFlow<PickedClip?>(null)
    val clip = _clip.asStateFlow()
    private val _cover = MutableStateFlow<Uri?>(null)
    val cover = _cover.asStateFlow()
    private val _busy = MutableStateFlow(false)
    val busy = _busy.asStateFlow()
    private val _status = MutableStateFlow<String?>(null)
    val status = _status.asStateFlow()
    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    /** The cover's type, read when it was picked; a copied file has none of its own. */
    private var coverMime: String? = null

    /**
     * Saved drafts for articles, recipes and polls; null for the other kinds.
     * Kept here so they survive rotation with the form.
     */
    val drafts: ComposerDraftKeeper? = when (kind) {
        ModeComposerKind.ARTICLE -> ComposerDraft.Kind.ARTICLE
        ModeComposerKind.RECIPE -> ComposerDraft.Kind.RECIPE
        ModeComposerKind.POLL -> ComposerDraft.Kind.POLL
        ModeComposerKind.DIVINE, ModeComposerKind.LISTING -> null
    }?.let { ComposerDraftKeeper(it, configStore.activeAccountHexPubkey.value, draftStore, viewModelScope) }

    /** The cover as a file, which is what a draft keeps. */
    val coverFile: File?
        get() = _cover.value?.takeIf { it.scheme == "file" }?.path?.let(::File)

    /**
     * A picked cover is copied into the app first: a draft can then keep it
     * after the picker's permission has lapsed, and publishing reads the same
     * bytes the preview showed.
     */
    fun setCover(uri: Uri?) {
        if (uri == null) {
            dropPickedCover()
            _cover.value = null
            coverMime = null
            return
        }
        viewModelScope.launch {
            val mime = context.contentResolver.getType(uri)
            val copy = withContext(Dispatchers.IO) {
                runCatching {
                    File.createTempFile(PICKED_COVER_PREFIX, ".img", context.cacheDir).also { f ->
                        context.contentResolver.openInputStream(uri)!!.use { input ->
                            f.outputStream().use { input.copyTo(it) }
                        }
                    }
                }.onFailure { Log.w(TAG, "Couldn't read the cover", it) }.getOrNull()
            } ?: return@launch
            dropPickedCover()
            _cover.value = Uri.fromFile(copy)
            coverMime = mime
        }
    }

    /** Loads a saved draft's cover, or clears the cover when it has none. */
    fun showDraftCover(file: File?, mime: String?) {
        dropPickedCover()
        _cover.value = file?.let(Uri::fromFile)
        coverMime = mime.takeIf { file != null }
    }

    /** The draft form of the cover's type, for [ComposerDraft.coverMime]. */
    fun currentCoverMime(): String? = coverMime.takeIf { _cover.value != null }

    /** Deletes a copy made by [setCover]; a saved draft's own cover stays. */
    private fun dropPickedCover() {
        coverFile?.takeIf { it.name.startsWith(PICKED_COVER_PREFIX) && it.parentFile == context.cacheDir }?.delete()
    }

    fun loadClip(uri: Uri) {
        viewModelScope.launch {
            _busy.value = true
            _error.value = null
            _status.value = "Getting the video ready…"
            try {
                _clip.value?.file?.delete()
                _clip.value = withContext(Dispatchers.IO) { readClip(uri) }
            } catch (e: Exception) {
                Log.e(TAG, "loadClip failed", e)
                _error.value = "Couldn't read that video."
            }
            _status.value = null
            _busy.value = false
        }
    }

    private fun readClip(uri: Uri): PickedClip {
        val mime = context.contentResolver.getType(uri) ?: "video/mp4"
        val ext = if (mime.contains("quicktime")) "mov" else "mp4"
        val file = File.createTempFile("divine_", ".$ext", context.cacheDir)
        context.contentResolver.openInputStream(uri)!!.use { input ->
            file.outputStream().use { input.copyTo(it) }
        }
        val picked = measure(file, mime)
        if (picked.durationSeconds * 1_000_000 <= TRIM_LIMIT_US) return picked
        // A long picked video is cut to its opening rather than uploaded whole.
        val trimmed = try {
            trimToLimit(file, picked.rotation)
        } finally {
            file.delete()
        }
        return measure(trimmed, "video/mp4").copy(wasTrimmed = true)
    }

    /**
     * Copies the opening of [source], up to [TRIM_LIMIT_US], into a new MP4
     * without re-encoding. The cut is at the last video keyframe before the
     * limit: B-frames just under it can reference a frame past it, and
     * dropping that frame would flicker on every loop. Audio a muxer can't
     * take (PCM in a .mov) is left out rather than failing the pick.
     */
    private fun trimToLimit(source: File, rotation: Int): File {
        val out = File.createTempFile("divine_trim_", ".mp4", context.cacheDir)
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            extractor.setDataSource(source.absolutePath)
            muxer = MediaMuxer(out.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val tracks = HashMap<Int, Int>()
            var videoTrack = -1
            var bufferSize = 1 shl 20
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val trackMime = format.getString(MediaFormat.KEY_MIME) ?: continue
                val isVideo = trackMime.startsWith("video/")
                if (!isVideo && !trackMime.startsWith("audio/")) continue
                val muxerTrack = try {
                    muxer.addTrack(format)
                } catch (e: Exception) {
                    if (isVideo) throw e
                    Log.w(TAG, "trim: dropping audio $trackMime: ${e.message}")
                    continue
                }
                extractor.selectTrack(i)
                tracks[i] = muxerTrack
                if (isVideo) videoTrack = i
                if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                    bufferSize = maxOf(bufferSize, format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
                }
            }
            muxer.setOrientationHint(rotation)
            // Find the last video keyframe at or before the limit. Only the
            // video track is selected while seeking, so the sync point is its.
            var cutUs = TRIM_LIMIT_US
            if (videoTrack >= 0) {
                val others = tracks.keys.filter { it != videoTrack }
                others.forEach { extractor.unselectTrack(it) }
                extractor.seekTo(TRIM_LIMIT_US, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                val keyUs = extractor.sampleTime
                // A clip with one long GOP has no keyframe to cut at; keep the limit.
                if (keyUs > 0) cutUs = keyUs
                others.forEach { extractor.selectTrack(it) }
                extractor.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            }
            muxer.start()
            val buffer = ByteBuffer.allocate(bufferSize)
            val info = MediaCodec.BufferInfo()
            val finished = HashSet<Int>()
            while (finished.size < tracks.size) {
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                val track = extractor.sampleTrackIndex
                val time = extractor.sampleTime
                // Once a track reaches the cut, later samples in decode order
                // (open-GOP leading B-frames) belong to the dropped keyframe.
                if (track in finished || time >= cutUs) {
                    finished.add(track)
                } else {
                    val keyFrame = extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0
                    info.set(0, size, time, if (keyFrame) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                    tracks[track]?.let { muxer.writeSampleData(it, buffer, info) }
                }
                extractor.advance()
            }
            muxer.stop()
            return out
        } catch (e: Exception) {
            out.delete()
            throw e
        } finally {
            muxer?.release()
            extractor.release()
        }
    }

    private fun measure(file: File, mime: String): PickedClip {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.absolutePath)
            val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            val ms = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0
            val frame = retriever.getFrameAtTime(100_000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: throw IllegalStateException("no frame")
            val (width, height) = if (rotation == 90 || rotation == 270) h to w else w to h
            return PickedClip(file, frame, width, height, ms / 1000.0, mime, rotation = rotation)
        } finally {
            retriever.release()
        }
    }

    private suspend fun upload(file: File, mime: String, label: String): Pair<String, String> {
        // Every file here is a temp copy, so the location can come out in place.
        if (!MediaPrivacy.removeLocation(file, mime)) throw IllegalStateException(MediaPrivacy.FAILURE_MESSAGE)
        val sha = blossomService.computeSHA256(file)
        val outcome = blossomService.uploadForPost(
            fileURL = file,
            sha256 = sha,
            contentType = mime,
            onProgress = { p -> _status.value = "Uploading $label… ${(p * 100).toInt()}%" },
        )
        val url = when (outcome) {
            is BlossomService.PostUploadOutcome.Hosted -> outcome.url
            is BlossomService.PostUploadOutcome.SavedOnDevice ->
                throw IllegalStateException("No outside media server took the upload. Try again when one is reachable.")
            BlossomService.PostUploadOutcome.NoOutsideServer ->
                throw IllegalStateException(MediaUploadOutcomeMessage.NO_OUTSIDE_SERVER)
            BlossomService.PostUploadOutcome.NotSavedOnDevice ->
                throw IllegalStateException(MediaUploadOutcomeMessage.NOT_SAVED_ON_DEVICE)
        }
        return url to sha
    }

    fun postDivine(title: String, caption: String, onDone: () -> Unit) {
        val clip = _clip.value ?: return
        // Locked at Post, before the uploads: see PostingAccount.
        val lock = nostrService.lockPostingAccount()
        viewModelScope.launch {
            _busy.value = true
            _error.value = null
            try {
                val (videoUrl, videoSha) = withContext(Dispatchers.IO) { upload(clip.file, clip.mimeType, "video") }
                val posterFile = withContext(Dispatchers.IO) {
                    File.createTempFile("divine_poster_", ".jpg", context.cacheDir).also { f ->
                        f.outputStream().use { clip.poster.compress(Bitmap.CompressFormat.JPEG, 80, it) }
                    }
                }
                val (posterUrl, _) = withContext(Dispatchers.IO) { upload(posterFile, "image/jpeg", "cover") }
                posterFile.delete()
                _status.value = "Posting…"
                val tags = DivinePost.tags(
                    videoUrl = videoUrl, videoSha256 = videoSha, videoBytes = clip.file.length(),
                    posterUrl = posterUrl, width = clip.width, height = clip.height,
                    durationSeconds = clip.durationSeconds, title = title.trim(), caption = caption.trim(),
                    publishedAt = System.currentTimeMillis() / 1000,
                )
                val event = nostrService.signEventAsync(kind = DivinePost.KIND, content = caption.trim(), tags = tags, lockedTo = lock)
                    ?: throw IllegalStateException("Couldn't sign the post. Check your key or remote signer in Settings.")
                nostrService.postEvent(event)
                val (accepted, message) = nostrService.publishAwaitingOk(event, Reel.DIVINE_RELAY)
                // Without the profile, diVine shows the post with no name and
                // can't find the account in search.
                nostrService.sendProfileTo(event.pubkey, Reel.DIVINE_RELAY)
                if (!accepted) {
                    notificationManager.showError(
                        "Posted to your relays, but diVine's relay didn't take it: ${message.ifBlank { "no reason given" }}",
                        ErrorStyle.WARNING,
                    )
                }
                clip.file.delete()
                reelsFeedService.refresh()
                onDone()
            } catch (e: Exception) {
                Log.e(TAG, "postDivine failed", e)
                // The switch may have closed this screen; the banner is seen either way.
                if (e is PostingAccount.AccountChangedException) notificationManager.showError(PostingAccount.MESSAGE)
                _error.value = e.message ?: "Couldn't post the diVine."
            }
            _status.value = null
            _busy.value = false
        }
    }

    fun publishLongForm(draft: LongFormDraft, onDone: () -> Unit) {
        val lock = nostrService.lockPostingAccount()
        viewModelScope.launch {
            _busy.value = true
            _error.value = null
            try {
                var imageUrl: String? = null
                _cover.value?.let { uri ->
                    val mime = coverMime ?: context.contentResolver.getType(uri) ?: "image/jpeg"
                    val file = withContext(Dispatchers.IO) {
                        File.createTempFile("cover_", ".img", context.cacheDir).also { f ->
                            context.contentResolver.openInputStream(uri)!!.use { input ->
                                f.outputStream().use { input.copyTo(it) }
                            }
                        }
                    }
                    imageUrl = withContext(Dispatchers.IO) { upload(file, mime, "cover") }.first
                    file.delete()
                }
                _status.value = "Publishing…"
                val final = draft.copy(imageUrl = imageUrl)
                val event = nostrService.signEventAsync(
                    kind = LongFormDraft.KIND,
                    content = final.content(),
                    tags = final.tags(System.currentTimeMillis() / 1000),
                    lockedTo = lock,
                ) ?: throw IllegalStateException("Couldn't sign the post. Check your key or remote signer in Settings.")
                nostrService.postEvent(event)
                drafts?.finish()
                onDone()
            } catch (e: Exception) {
                Log.e(TAG, "publishLongForm failed", e)
                // The switch may have closed this screen; the banner is seen either way.
                if (e is PostingAccount.AccountChangedException) notificationManager.showError(PostingAccount.MESSAGE)
                _error.value = e.message ?: "Couldn't publish."
            }
            _status.value = null
            _busy.value = false
        }
    }

    /**
     * Publishes a kind 1068 poll the way a vote goes out: this device's relay
     * and Blastr through postEvent, and without waiting to the outside relays
     * it names for its votes, so voters look where it lives. Port of iOS
     * PollComposeView.publish.
     */
    fun publishPoll(draft: com.nostrvault.data.model.PollDraft, onDone: () -> Unit) {
        val nowSecs = System.currentTimeMillis() / 1000
        if (!draft.isComplete(nowSecs)) return
        val lock = nostrService.lockPostingAccount()
        val relays = configStore.config.value.writeRelays.filter { it.startsWith("wss://") }
            .ifEmpty { com.nostrvault.relay.RelayConfiguration.FALLBACK_WRITE_RELAYS }
        viewModelScope.launch {
            _busy.value = true
            _error.value = null
            try {
                val tags = draft.tags(relays)
                val event = nostrService.signEventAsync(
                    kind = com.nostrvault.data.model.NIP88Poll.KIND,
                    content = draft.trimmedQuestion,
                    tags = tags,
                    lockedTo = lock,
                ) ?: throw IllegalStateException("Couldn't sign the poll. Check your key or remote signer in Settings.")
                nostrService.postEvent(event)
                nostrService.publishFireAndForget(event, tags.filter { it.size >= 2 && it[0] == "relay" }.map { it[1] })
                drafts?.finish()
                onDone()
            } catch (e: Exception) {
                Log.e(TAG, "publishPoll failed", e)
                if (e is PostingAccount.AccountChangedException) notificationManager.showError(PostingAccount.MESSAGE)
                _error.value = e.message ?: "Couldn't post the poll."
            }
            _busy.value = false
        }
    }

    /**
     * Uploads the photos, then publishes a 30402 listing to the owner's relays
     * and the marketplace relays, which are where the grid, Shopstr and
     * Plebeian look. Port of MarketplaceSellView.publish on iPhone.
     */
    fun publishListing(draft: com.nostrvault.data.model.ListingDraft, photos: List<Uri>, onDone: () -> Unit) {
        val lock = nostrService.lockPostingAccount()
        viewModelScope.launch {
            _busy.value = true
            _error.value = null
            try {
                val urls = mutableListOf<String>()
                photos.forEachIndexed { index, uri ->
                    val label = if (photos.size == 1) "photo" else "photo ${index + 1} of ${photos.size}"
                    val file = withContext(Dispatchers.IO) { listingJpeg(uri) }
                    urls += withContext(Dispatchers.IO) { upload(file, "image/jpeg", label) }.first
                    file.delete()
                }
                _status.value = "Publishing…"
                val final = draft.copy(imageUrls = urls)
                val event = nostrService.signEventAsync(
                    kind = com.nostrvault.data.model.ListingDraft.KIND,
                    content = final.content(),
                    tags = final.tags(System.currentTimeMillis() / 1000),
                    lockedTo = lock,
                ) ?: throw IllegalStateException("Couldn't sign the listing. Check your key or remote signer in Settings.")
                nostrService.postEvent(event)
                val results = kotlinx.coroutines.coroutineScope {
                    com.nostrvault.service.MarketplaceFeedService.RELAYS.map { relay ->
                        async { nostrService.publishAwaitingOk(event, relay).first }
                    }.map { it.await() }
                }
                if (results.none { it }) {
                    notificationManager.showError(
                        "Listed on your relays, but no marketplace relay took it, so Plebeian Market may not show it yet.",
                        ErrorStyle.WARNING,
                    )
                }
                marketplaceFeedService.refresh()
                onDone()
            } catch (e: Exception) {
                Log.e(TAG, "publishListing failed", e)
                // The switch may have closed this screen; the banner is seen either way.
                if (e is PostingAccount.AccountChangedException) notificationManager.showError(PostingAccount.MESSAGE)
                _error.value = e.message ?: "Couldn't list it."
            }
            _status.value = null
            _busy.value = false
        }
    }

    /**
     * A picked photo re-encoded as a JPEG at most 2048px on its long side.
     * Decoding and re-encoding drops EXIF, so the phone's GPS position never
     * goes out with the listing.
     */
    private fun listingJpeg(uri: Uri): File {
        val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)!!.use { android.graphics.BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= 2048) sample *= 2
        val decoded = context.contentResolver.openInputStream(uri)!!.use {
            android.graphics.BitmapFactory.decodeStream(it, null, android.graphics.BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: throw IllegalStateException("Couldn't read one of those photos.")
        val rotated = rotateForExif(uri, decoded)
        val scale = 2048f / maxOf(rotated.width, rotated.height)
        val sized = if (scale < 1f) {
            Bitmap.createScaledBitmap(rotated, (rotated.width * scale).toInt(), (rotated.height * scale).toInt(), true)
        } else rotated
        return File.createTempFile("listing_", ".jpg", context.cacheDir).also { f ->
            f.outputStream().use { sized.compress(Bitmap.CompressFormat.JPEG, 85, it) }
        }
    }

    /** Applies the EXIF orientation before it is stripped, so photos stay upright. */
    private fun rotateForExif(uri: Uri, bitmap: Bitmap): Bitmap {
        val orientation = runCatching {
            context.contentResolver.openInputStream(uri)!!.use {
                android.media.ExifInterface(it).getAttributeInt(
                    android.media.ExifInterface.TAG_ORIENTATION,
                    android.media.ExifInterface.ORIENTATION_NORMAL,
                )
            }
        }.getOrDefault(android.media.ExifInterface.ORIENTATION_NORMAL)
        val degrees = when (orientation) {
            android.media.ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            android.media.ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            android.media.ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> return bitmap
        }
        val matrix = android.graphics.Matrix().apply { postRotate(degrees) }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    override fun onCleared() {
        _clip.value?.file?.delete()
        dropPickedCover()
    }

    companion object {
        private const val TAG = "ModeCompose"
        private const val PICKED_COVER_PREFIX = "picked_cover_"
        /** diVine's camera records six-second loops. */
        const val RECORD_LIMIT_SECONDS = 6
        /** Picked videos past this are trimmed; matches iOS's 6.3 s. */
        const val TRIM_LIMIT_US = 6_300_000L
    }
}
