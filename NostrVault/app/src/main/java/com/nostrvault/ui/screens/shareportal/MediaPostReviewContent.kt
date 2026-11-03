package com.nostrvault.ui.screens.shareportal

import android.content.Context
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import coil.compose.AsyncImage
import coil.decode.VideoFrameDecoder
import coil.request.ImageRequest
import androidx.compose.ui.platform.LocalContext
import com.nostrvault.service.NostrService
import com.nostrvault.service.shareportal.MediaPostSharePublisher
import com.nostrvault.service.shareportal.handlers.MediaPostShareTags
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.shareportal.ShareQueue
import com.nostrvault.ui.components.ProseKeyboardOptions
import com.nostrvault.ui.theme.SecondaryText
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File
import javax.inject.Inject

/**
 * Review card for a shared picture or video post: the files, an optional
 * title, a caption, and an explicit Publish. Nothing uploads before the tap.
 * Twin: MediaPostReviewView.swift.
 */
@Composable
internal fun MediaPostReviewContent(
    intent: ShareIntent,
    needsSwitch: Boolean,
    onSwitchAccount: (String) -> Unit,
    onDone: () -> Unit,
    onDismiss: () -> Unit,
    viewModel: MediaPostReviewViewModel = hiltViewModel(key = "media-post-${intent.id}"),
) {
    val busy by viewModel.busy.collectAsState()
    val status by viewModel.status.collectAsState()
    val error by viewModel.error.collectAsState()
    var title by remember(intent.id) { mutableStateOf(intent.form["title"].orEmpty()) }
    var caption by remember(intent.id) { mutableStateOf(intent.form["caption"] ?: intent.source.text.orEmpty()) }
    val files = remember(intent.id) { viewModel.files(intent) }
    val shape = remember(intent.id) { MediaPostShareTags.shape(intent.files.map { it.mime }) }
    val isVideo = shape.shape == MediaPostShareTags.Shape.VIDEO
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Picture or video post", style = MaterialTheme.typography.titleMedium)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            files.forEach { f ->
                val video = MediaPostShareTags.isVideo(f.mime)
                AsyncImage(
                    // A video shows its first frame (Coil's video decoder, not registered app-wide).
                    model = ImageRequest.Builder(LocalContext.current).data(f.file)
                        .apply { if (video) decoderFactory(VideoFrameDecoder.Factory()) }.build(),
                    contentDescription = if (video) "Shared video" else "Shared picture",
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.size(96.dp).clip(RoundedCornerShape(8.dp)),
                )
            }
        }
        shape.problem?.let { Text(it.message, color = MaterialTheme.colorScheme.error) }
        if (files.size < intent.files.size) Text("Some shared files are missing.", color = MaterialTheme.colorScheme.error)
        OutlinedTextField(
            value = title,
            onValueChange = { title = it },
            label = { Text(if (isVideo) "Title" else "Title (optional)") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = caption,
            onValueChange = { caption = it },
            label = { Text("Caption") },
            keyboardOptions = ProseKeyboardOptions,
            minLines = 2,
            maxLines = 8,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            if (isVideo) "Posts are public. A video without a title uses the caption's first line."
            else "Posts are public. Where each picture was taken is removed before it uploads.",
            color = SecondaryText,
            style = MaterialTheme.typography.bodySmall,
        )
        val wanted = intent.account
        if (wanted != null && needsSwitch) {
            Text("This was shared for another of your accounts.", color = SecondaryText)
            OutlinedButton(onClick = { onSwitchAccount(wanted) }, enabled = !busy) { Text("Switch to that account") }
        }
        status?.takeIf { busy }?.let { Text(it, color = SecondaryText) }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                onClick = { viewModel.publish(intent, files, title, caption, onDone) },
                enabled = !busy && shape.problem == null && files.size == intent.files.size && !needsSwitch,
            ) { Text(if (busy) "Publishing…" else "Publish") }
            TextButton(onClick = onDismiss, enabled = !busy) { Text("Dismiss") }
        }
    }
}

@HiltViewModel
class MediaPostReviewViewModel @Inject constructor(
    @ApplicationContext context: Context,
    private val publisher: MediaPostSharePublisher,
    private val nostrService: NostrService,
) : ViewModel() {
    private val queue = ShareQueue.forApp(context)

    private val _busy = MutableStateFlow(false)
    val busy = _busy.asStateFlow()
    private val _status = MutableStateFlow<String?>(null)
    val status = _status.asStateFlow()
    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    /** The claimed copies that are still on disk. */
    fun files(intent: ShareIntent): List<MediaPostSharePublisher.Shared> = intent.files.mapNotNull { f ->
        queue.claimedFile(intent, f)?.takeIf(File::isFile)?.let { MediaPostSharePublisher.Shared(it, f.mime) }
    }

    fun publish(intent: ShareIntent, files: List<MediaPostSharePublisher.Shared>, title: String, caption: String, onDone: () -> Unit) {
        if (_busy.value) return
        // Locked at Publish, before the uploads: see PostingAccount.
        val lock = nostrService.lockPostingAccount()
        if (intent.account != null && intent.account != lock.npub) {
            _error.value = "Switch to that account first."
            return
        }
        _busy.value = true
        _error.value = null
        viewModelScope.launch {
            try {
                publisher.publish(files, title, caption, lock) { _status.value = it }
                onDone()
            } catch (e: MediaPostSharePublisher.PublishException) {
                _error.value = e.message
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                _error.value = "Couldn't post it. Nothing was published."
            } finally {
                _busy.value = false
                _status.value = null
            }
        }
    }
}
