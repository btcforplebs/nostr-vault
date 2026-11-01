package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.ui.theme.*

@Composable
internal fun AttachmentGrid(
    attachments: List<Attachment>,
    /** Each attachment's upload, which starts when it is picked; a ring shows while it runs. */
    uploads: Map<String, ComposeNoteUpload> = emptyMap(),
    onRemove: (String) -> Unit,
    onEditAlt: (Attachment) -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        attachments.forEach { attachment ->
            Box(
                modifier = Modifier
                    .size(72.dp)
                    .clip(RoundedCornerShape(10.dp))
            ) {
                // Image/video preview; audio has no picture, so iOS's waveform tile.
                if (attachment.mimeType.startsWith("audio/")) {
                    AudioThumbnail(iconSize = 28.dp)
                } else {
                    AsyncImage(
                        model = attachment.uri,
                        contentDescription = null,
                        modifier = Modifier.fillMaxSize(),
                        contentScale = ContentScale.Crop
                    )
                }

                // Video indicator
                if (attachment.isVideo) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .background(Color.Black.copy(alpha = 0.3f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = Icons.Default.PlayArrow,
                            contentDescription = "Video",
                            tint = Color.White,
                            modifier = Modifier.size(32.dp)
                        )
                    }
                }

                UploadRing(uploads[attachment.id], attachment.hostedUrl != null)

                // Remove button
                IconButton(
                    onClick = { onRemove(attachment.id) },
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(4.dp)
                        .size(24.dp)
                        .background(Color.Black.copy(alpha = 0.6f), CircleShape)
                ) {
                    Icon(
                        imageVector = Icons.Default.Close,
                        contentDescription = "Remove",
                        tint = Color.White,
                        modifier = Modifier.size(16.dp)
                    )
                }

                // ALT chip: filled once the attachment has a description,
                // hollow while it has none, so an undescribed image is visible
                // as such at a glance rather than only after publishing.
                val described = attachment.altText.isNotBlank()
                Text(
                    text = "ALT",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White,
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .padding(6.dp)
                        .clip(RoundedCornerShape(50))
                        .background(
                            if (described) LocalNostrVaultColors.current.primary
                            else Color.Black.copy(alpha = 0.55f)
                        )
                        .clickable { onEditAlt(attachment) }
                        .padding(horizontal = 8.dp, vertical = 4.dp)
                        .semantics {
                            contentDescription =
                                if (described) "Edit description: ${attachment.altText}"
                                else "Add a description for this media"
                        }
                )
            }
        }
    }
}

/** The upload's progress over the thumbnail; a phone once it is saved here only, a warning if it failed. */
@Composable
private fun BoxScope.UploadRing(upload: ComposeNoteUpload?, alreadyHosted: Boolean) {
    // Up on a server: nothing over the picture.
    if (alreadyHosted || (upload is ComposeNoteUpload.Done && upload.media.url != null)) return
    val label = when (upload) {
        null, ComposeNoteUpload.Waiting -> "Waiting to upload"
        is ComposeNoteUpload.Sending -> "Uploading, ${(upload.progress * 100).toInt()} percent"
        is ComposeNoteUpload.Done -> "Saved on this device, posts when a server answers"
        is ComposeNoteUpload.Failed -> "Upload failed, Post tries again"
    }
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.35f))
            .semantics { contentDescription = label },
    ) {
        when (upload) {
            is ComposeNoteUpload.Sending -> CircularProgressIndicator(
                progress = { upload.progress.coerceIn(0.02f, 1f) },
                color = Color.White,
                trackColor = Color.White.copy(alpha = 0.3f),
                strokeWidth = 3.dp,
                modifier = Modifier.size(30.dp),
            )
            is ComposeNoteUpload.Failed -> Icon(Icons.Default.ErrorOutline, contentDescription = null, tint = Color.White, modifier = Modifier.size(26.dp))
            is ComposeNoteUpload.Done -> Icon(Icons.Default.PhoneAndroid, contentDescription = null, tint = Color.White, modifier = Modifier.size(22.dp))
            else -> CircularProgressIndicator(color = Color.White, trackColor = Color.White.copy(alpha = 0.3f), strokeWidth = 3.dp, modifier = Modifier.size(30.dp))
        }
    }
}
