package com.nostrvault.ui.screens

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.MediaStore
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
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
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import javax.inject.Inject

/** What the post button writes in feeds that show something other than notes. */
enum class ModeComposerKind(val route: String, val buttonTitle: String) {
    DIVINE("divine", "diVine"),
    ARTICLE("article", "Write"),
    RECIPE("recipe", "Recipe");

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
            return PickedClip(file, frame, width, height, ms / 1000.0, mime)
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
                nostrService.publishTo(event, Reel.DIVINE_RELAY)
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

    override fun onCleared() {
        _clip.value?.file?.delete()
    }

    companion object {
        private const val TAG = "ModeCompose"
        /** diVine's camera records six-second loops. */
        const val RECORD_LIMIT_SECONDS = 6
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

    var title by remember { mutableStateOf("") }
    var summary by remember { mutableStateOf("") }
    var body by remember { mutableStateOf("") }
    var prepTime by remember { mutableStateOf("") }
    var cookTime by remember { mutableStateOf("") }
    var servings by remember { mutableStateOf("") }
    var ingredients by remember { mutableStateOf("") }
    var directions by remember { mutableStateOf("") }
    var categories by remember { mutableStateOf("") }

    val kind = viewModel.kind
    val canPost = when (kind) {
        ModeComposerKind.DIVINE -> clip != null
        ModeComposerKind.ARTICLE -> title.isNotBlank() && body.isNotBlank()
        ModeComposerKind.RECIPE -> title.isNotBlank() &&
            LongFormDraft.lines(ingredients).isNotEmpty() && LongFormDraft.lines(directions).isNotEmpty()
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
                    Field(title, { title = it }, "Title")
                    Field(body, { body = it }, "Say something about it (#tags work)", minLines = 2)
                    clip?.let {
                        Text(
                            "${Math.round(it.durationSeconds)}s · ${it.width}×${it.height}",
                            color = SecondaryText, fontSize = 12.sp,
                        )
                    }
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

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(9f / 16f)
            .heightIn(max = 460.dp)
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
            Text("A short looping video", color = Color.White.copy(alpha = 0.8f))
        }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Button(
            onClick = {
                if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                    launchCamera()
                } else {
                    cameraPermission.launch(Manifest.permission.CAMERA)
                }
            },
            enabled = !busy,
            colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
        ) {
            Icon(NostrVaultIcons.Video, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text("Record")
        }
        OutlinedButton(
            onClick = { pickVideo.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly)) },
            enabled = !busy,
        ) {
            Text(if (clip == null) "Choose" else "Choose another")
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
