package com.nostrvault.ui.screens.dm

import android.net.Uri
import android.webkit.MimeTypeMap
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import coil.decode.VideoFrameDecoder
import coil.request.ImageRequest

/**
 * Videos in DMs (Logen 2026-11-06): the photo button picks a video too, it
 * goes up through the same upload as a photo, and its link is sent in the
 * message (DMAttachment). Twin of iOS DMVideoAttachment.swift.
 */
internal object DMVideo {
    fun isVideoMime(type: String?): Boolean = type?.lowercase()?.startsWith("video/") == true

    /** The file extension a video's MIME type names, "mp4" when unknown. */
    fun extension(mime: String): String =
        MimeTypeMap.getSingleton().getExtensionFromMimeType(mime.lowercase())
            ?: if (mime.lowercase() == "video/quicktime") "mov" else "mp4"
}

/** A video a message carries: a play tile; a tap opens the viewer, which plays it. */
@Composable
internal fun DMVideoTile(size: Dp, onClick: () -> Unit) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(size)
            .background(Color.Black.copy(alpha = 0.85f))
            .clickable(onClick = onClick)
            .semantics { contentDescription = "Video" },
    ) {
        Icon(Icons.Filled.PlayCircle, contentDescription = null, tint = Color.White, modifier = Modifier.size(44.dp))
    }
}

/** The attached photo or video above the message box; a video shows its first frame. */
@Composable
internal fun DMAttachmentThumbnail(uri: Uri, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val video = remember(uri) { DMVideo.isVideoMime(context.contentResolver.getType(uri)) }
    Box(modifier, contentAlignment = Alignment.Center) {
        AsyncImage(
            model = ImageRequest.Builder(context).data(uri)
                .apply { if (video) decoderFactory(VideoFrameDecoder.Factory()) }.build(),
            contentDescription = if (video) "Attached video" else "Attached image",
            contentScale = ContentScale.Crop,
            modifier = Modifier.matchParentSize(),
        )
        if (video) {
            Icon(Icons.Filled.PlayCircle, contentDescription = null, tint = Color.White, modifier = Modifier.size(22.dp))
        }
    }
}
