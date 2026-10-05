package com.nostrvault.ui.screens

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.net.Uri
import android.provider.MediaStore
import android.util.Log
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.model.DivinePost
import com.nostrvault.data.model.LongFormDraft
import com.nostrvault.data.model.MediaUploadOutcomeMessage
import com.nostrvault.data.model.Reel
import com.nostrvault.service.BlossomService
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
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import javax.inject.Inject

/** What the post button writes in feeds that show something other than notes. */
enum class ModeComposerKind(val route: String, val buttonTitle: String) {
    DIVINE("divine", "diVine"),
    ARTICLE("article", "Write"),
    RECIPE("recipe", "Recipe"),
    /** A NIP-99 listing for the Marketplace; see MarketplaceSellScreen. */
    LISTING("listing", "Sell");

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

    fun setCover(uri: Uri?) { _cover.value = uri }

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
                val event = nostrService.signEventAsync(kind = DivinePost.KIND, content = caption.trim(), tags = tags)
                    ?: throw IllegalStateException("Couldn't sign the post. Check your key or remote signer in Settings.")
                nostrService.postEvent(event)
                val (accepted, message) = nostrService.publishAwaitingOk(event, Reel.DIVINE_RELAY)
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
                _error.value = e.message ?: "Couldn't post the diVine."
            }
            _status.value = null
            _busy.value = false
        }
    }

    fun publishLongForm(draft: LongFormDraft, onDone: () -> Unit) {
        viewModelScope.launch {
            _busy.value = true
            _error.value = null
            try {
                var imageUrl: String? = null
                _cover.value?.let { uri ->
                    val mime = context.contentResolver.getType(uri) ?: "image/jpeg"
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
                ) ?: throw IllegalStateException("Couldn't sign the post. Check your key or remote signer in Settings.")
                nostrService.postEvent(event)
                onDone()
            } catch (e: Exception) {
                Log.e(TAG, "publishLongForm failed", e)
                _error.value = e.message ?: "Couldn't publish."
            }
            _status.value = null
            _busy.value = false
        }
    }

    /**
     * Uploads the photos, then publishes a 30402 listing to the owner's relays
     * and the marketplace relays, which are where the grid, Shopstr and
     * Plebeian look. Port of MarketplaceSellView.publish on iPhone.
     */
    fun publishListing(draft: com.nostrvault.data.model.ListingDraft, photos: List<Uri>, onDone: () -> Unit) {
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
                ) ?: throw IllegalStateException("Couldn't sign the listing. Check your key or remote signer in Settings.")
                nostrService.postEvent(event)
                val results = kotlinx.coroutines.coroutineScope {
                    com.nostrvault.service.MarketplaceFeedService.RELAYS.map { relay ->
                        async { nostrService.publishAwaitingOk(event, relay).first }
                    }.map { it.await() }
                }
                if (results.none { it }) {
                    notificationManager.showError(
                        "Listed on your relays, but no marketplace relay took it, so Shopstr and Plebeian may not show it yet.",
                        ErrorStyle.WARNING,
                    )
                }
                marketplaceFeedService.refresh()
                onDone()
            } catch (e: Exception) {
                Log.e(TAG, "publishListing failed", e)
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
    }

    companion object {
        private const val TAG = "ModeCompose"
        /** diVine's camera records six-second loops. */
        const val RECORD_LIMIT_SECONDS = 6
        /** Picked videos past this are trimmed; matches iOS's 6.3 s. */
        const val TRIM_LIMIT_US = 6_300_000L
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModeComposeScreen(
    onDone: () -> Unit,
    viewModel: ModeComposeViewModel = hiltViewModel(),
) {
    val colors = LocalNostrVaultColors.current
    val busy by viewModel.busy.collectAsState()
    val status by viewModel.status.collectAsState()
    val error by viewModel.error.collectAsState()
    val clip by viewModel.clip.collectAsState()
    val cover by viewModel.cover.collectAsState()

    var title by rememberSaveable { mutableStateOf("") }
    var summary by rememberSaveable { mutableStateOf("") }
    var body by rememberSaveable { mutableStateOf("") }
    var prepTime by rememberSaveable { mutableStateOf("") }
    var cookTime by rememberSaveable { mutableStateOf("") }
    var servings by rememberSaveable { mutableStateOf("") }
    var ingredients by rememberSaveable { mutableStateOf("") }
    var directions by rememberSaveable { mutableStateOf("") }
    var categories by rememberSaveable { mutableStateOf("") }

    // The X is disabled while busy; system back would otherwise pop the
    // route and cancel the upload or post partway through.
    BackHandler(enabled = busy) {}

    val kind = viewModel.kind
    if (kind == ModeComposerKind.LISTING) {
        MarketplaceSellScreen(onDone = onDone, viewModel = viewModel)
        return
    }
    val canPost = when (kind) {
        ModeComposerKind.DIVINE -> clip != null
        ModeComposerKind.ARTICLE -> title.isNotBlank() && body.isNotBlank()
        ModeComposerKind.RECIPE -> title.isNotBlank() &&
            LongFormDraft.lines(ingredients).isNotEmpty() && LongFormDraft.lines(directions).isNotEmpty()
        ModeComposerKind.LISTING -> false
    }

    fun submit() {
        when (kind) {
            ModeComposerKind.DIVINE -> viewModel.postDivine(title, body, onDone)
            ModeComposerKind.ARTICLE -> viewModel.publishLongForm(
                LongFormDraft(title = title, summary = summary, body = body), onDone)
            ModeComposerKind.RECIPE -> viewModel.publishLongForm(
                LongFormDraft(
                    title = title, summary = summary, body = body,
                    recipe = LongFormDraft.Recipe(prepTime, cookTime, servings, ingredients, directions, categories),
                ), onDone)
            ModeComposerKind.LISTING -> Unit
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        when (kind) {
                            ModeComposerKind.DIVINE -> "New diVine"
                            ModeComposerKind.ARTICLE -> "New article"
                            ModeComposerKind.RECIPE -> "New recipe"
                            ModeComposerKind.LISTING -> "Sell something"
                        }
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onDone, enabled = !busy) {
                        Icon(NostrVaultIcons.Dismiss, contentDescription = "Cancel")
                    }
                },
                actions = {
                    Button(
                        onClick = { submit() },
                        enabled = canPost && !busy,
                        colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                        shape = RoundedCornerShape(20.dp),
                        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 8.dp),
                    ) {
                        if (busy) {
                            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = PrimaryText)
                        } else {
                            Text(
                                if (kind == ModeComposerKind.DIVINE) "Post" else "Publish",
                                fontWeight = FontWeight.SemiBold,
                                color = PrimaryText,
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                ),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (kind == ModeComposerKind.DIVINE) {
                DivineVideoArea(clip = clip, busy = busy, onPicked = viewModel::loadClip)
                if (clip != null) {
                    Field(title, { title = it }, "Title (optional)")
                    Field(body, { body = it }, "Caption (optional) — #tags work", minLines = 2)
                }
            } else {
                CoverPicker(cover = cover, onPicked = viewModel::setCover)
                Field(title, { title = it }, "Title")
                Field(summary, { summary = it },
                    if (kind == ModeComposerKind.RECIPE) "Short description" else "Summary (optional)")
                if (kind == ModeComposerKind.RECIPE) {
                    Field(prepTime, { prepTime = it }, "Prep time, e.g. 15 min")
                    Field(cookTime, { cookTime = it }, "Cook time, e.g. 30 min")
                    Field(servings, { servings = it }, "Servings")
                    Field(ingredients, { ingredients = it }, "Ingredients, one per line", minLines = 5)
                    Field(directions, { directions = it }, "Directions, one step per line", minLines = 6)
                    Field(body, { body = it }, "Chef's notes (optional)", minLines = 3)
                    Field(categories, { categories = it }, "Categories, comma separated")
                } else {
                    Field(body, { body = it }, "Article. Markdown works: # headings, **bold**, - lists", minLines = 12)
                }
            }
            status?.let {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = colors.primary)
                    Text(it, color = SecondaryText, fontSize = 13.sp)
                }
            }
            error?.let { Text(it, color = Color(0xFFFF453A), fontSize = 13.sp) }
        }
    }
}

@Composable
private fun Field(value: String, onChange: (String) -> Unit, label: String, minLines: Int = 1) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        minLines = minLines,
        singleLine = minLines == 1,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun DivineVideoArea(clip: PickedClip?, busy: Boolean, onPicked: (Uri) -> Unit) {
    val context = LocalContext.current
    val colors = LocalNostrVaultColors.current
    val pickVideo = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri?.let(onPicked)
    }
    val record = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        result.data?.data?.let(onPicked)
    }
    fun launchCamera() {
        record.launch(
            Intent(MediaStore.ACTION_VIDEO_CAPTURE)
                .putExtra(MediaStore.EXTRA_DURATION_LIMIT, ModeComposeViewModel.RECORD_LIMIT_SECONDS)
        )
    }
    // The manifest declares CAMERA (QR scanning), so the system camera intent
    // is refused until the permission is granted.
    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) launchCamera()
    }

    val limit = ModeComposeViewModel.RECORD_LIMIT_SECONDS
    // The one rule a diVine has, said before anything is picked.
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Text("A looping video, up to $limit seconds", color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(2.dp))
        Text(
            "Record one, or choose a video. Longer videos keep their first $limit seconds.",
            color = SecondaryText, fontSize = 13.sp, textAlign = TextAlign.Center,
        )
    }

    // The cap goes on before aspectRatio, which then sizes from that height;
    // after it, a full-width 9:16 box is already ~640dp and the cap is ignored.
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Box(
            modifier = Modifier
                .heightIn(max = 420.dp)
                .aspectRatio(9f / 16f, matchHeightConstraintsFirst = true)
                .clip(RoundedCornerShape(16.dp))
                .background(Color.Black),
            contentAlignment = Alignment.Center,
        ) {
            if (clip != null) {
                Image(
                    bitmap = clip.poster.asImageBitmap(),
                    contentDescription = "Chosen video",
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize(),
                )
            } else if (busy) {
                CircularProgressIndicator(color = Color.White)
            } else {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.semantics(mergeDescendants = true) {
                        contentDescription = "Up to $limit seconds"
                    },
                ) {
                    Text("${limit}s", color = Color.White, fontSize = 56.sp, fontWeight = FontWeight.Black)
                    Text("max length", color = Color.White.copy(alpha = 0.7f), fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }

    clip?.let { LengthMeter(it, limit) }

    fun record() {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            launchCamera()
        } else {
            cameraPermission.launch(Manifest.permission.CAMERA)
        }
    }
    fun choose() = pickVideo.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly))
    val outline = ButtonDefaults.outlinedButtonColors(contentColor = colors.primary)
    val border = BorderStroke(1.dp, colors.primary.copy(alpha = 0.6f))

    if (clip == null) {
        // Stacked and large while they are the next step.
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(
                onClick = ::record,
                enabled = !busy,
                colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                modifier = Modifier.fillMaxWidth().height(52.dp),
            ) {
                Icon(NostrVaultIcons.Video, contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text("Record a video", color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
            OutlinedButton(
                onClick = ::choose,
                enabled = !busy,
                colors = outline,
                border = border,
                modifier = Modifier.fillMaxWidth().height(52.dp),
            ) {
                Text("Choose from gallery", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    } else if (!busy) {
        // A compact row once there is a clip; Post is the next step.
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedButton(onClick = ::record, colors = outline, border = border, modifier = Modifier.weight(1f)) {
                Icon(NostrVaultIcons.Video, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("Record again", maxLines = 1)
            }
            OutlinedButton(onClick = ::choose, colors = outline, border = border, modifier = Modifier.weight(1f)) {
                Text("Choose another", maxLines = 1)
            }
        }
    }
}

/** How much of the limit the picked clip uses. */
@Composable
private fun LengthMeter(clip: PickedClip, limit: Int) {
    val colors = LocalNostrVaultColors.current
    val used = (clip.durationSeconds / limit).toFloat().coerceIn(0f, 1f)
    Column(
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.fillMaxWidth().semantics(mergeDescendants = true) {},
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(6.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(SecondaryText.copy(alpha = 0.25f)),
        ) {
            Box(
                Modifier
                    .fillMaxWidth(used)
                    .height(6.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(colors.primary),
            )
        }
        Row(Modifier.fillMaxWidth()) {
            Text(
                String.format(java.util.Locale.US, "%.1fs of %ds", clip.durationSeconds, limit),
                color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.weight(1f))
            Text(if (clip.wasTrimmed) "Trimmed to fit" else "Fits", color = SecondaryText, fontSize = 13.sp)
        }
    }
}

@Composable
private fun CoverPicker(cover: Uri?, onPicked: (Uri?) -> Unit) {
    val context = LocalContext.current
    val colors = LocalNostrVaultColors.current
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) onPicked(uri)
    }
    val preview = remember(cover) {
        cover?.let { uri ->
            runCatching {
                context.contentResolver.openInputStream(uri)?.use { input ->
                    val opts = BitmapFactory.Options().apply { inSampleSize = 4 }
                    BitmapFactory.decodeStream(input, null, opts)
                }
            }.getOrNull()
        }
    }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(160.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.08f))
            .clickable { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
        contentAlignment = Alignment.Center,
    ) {
        if (preview != null) {
            Image(preview.asImageBitmap(), contentDescription = "Cover photo",
                contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        } else {
            Text("Add a cover photo", color = colors.primary)
        }
    }
}
