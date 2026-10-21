package com.nostrvault.ui.screens

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.net.Uri
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTarget
import androidx.compose.ui.draganddrop.mimeTypes
import androidx.compose.ui.draganddrop.toAndroidDragEvent
import androidx.compose.ui.platform.LocalContext

/** A drag carrying a photo or video is ours to take; anything else (text, a file) is not. */
internal fun carriesDroppableMedia(mimeTypes: Collection<String>): Boolean =
    mimeTypes.any { it.startsWith("image/") || it.startsWith("video/") }

/**
 * Photos and videos dragged in from Photos, Files or a browser (split-screen
 * or a tablet) join the note's attachments, the same as ones picked from the
 * footer. iOS ComposeView `.onDrop`. The attachment cap is enforced by
 * [ComposeNoteViewModel.addAttachments], which a drop goes through.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun Modifier.mediaDropTarget(enabled: Boolean, onDrop: (List<Uri>) -> Unit): Modifier {
    val context = LocalContext.current
    val currentEnabled by rememberUpdatedState(enabled)
    val currentOnDrop by rememberUpdatedState(onDrop)
    val target = remember {
        object : DragAndDropTarget {
            override fun onDrop(event: DragAndDropEvent): Boolean {
                if (!currentEnabled) return false
                val android = event.toAndroidDragEvent()
                val clip = android.clipData ?: return false
                // Content URIs from another app are readable only for this grant.
                context.findActivity()?.requestDragAndDropPermissions(android)
                val uris = (0 until clip.itemCount).mapNotNull { i ->
                    val uri = clip.getItemAt(i).uri ?: return@mapNotNull null
                    val type = context.contentResolver.getType(uri)
                    uri.takeIf { type != null && carriesDroppableMedia(listOf(type)) }
                }
                if (uris.isEmpty()) return false
                currentOnDrop(uris)
                return true
            }
        }
    }
    return dragAndDropTarget(
        shouldStartDragAndDrop = { event -> currentEnabled && carriesDroppableMedia(event.mimeTypes()) },
        target = target,
    )
}

private fun Context.findActivity(): Activity? {
    var c: Context? = this
    while (c is ContextWrapper) {
        if (c is Activity) return c
        c = c.baseContext
    }
    return null
}
