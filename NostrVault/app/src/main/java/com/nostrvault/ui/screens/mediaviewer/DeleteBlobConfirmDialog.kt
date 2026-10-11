package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import com.nostrvault.ui.theme.*

/** Red tap-to-dismiss banner naming where a delete left the file. Port of the iOS viewer's failure banner. */
@Composable
internal fun DeleteLeftoverBanner(message: String, onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        onClick = onDismiss,
        shape = RoundedCornerShape(18.dp),
        color = Color(0xCCE53935),
        contentColor = Color.White,
        modifier = modifier,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(vertical = 12.dp, horizontal = 16.dp),
        ) {
            Icon(NostrVaultIcons.Alert, contentDescription = null, modifier = Modifier.size(16.dp))
            Text(
                message,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            Icon(NostrVaultIcons.Dismiss, contentDescription = "Dismiss", modifier = Modifier.size(12.dp).graphicsLayer { alpha = 0.7f })
        }
    }
}

/**
 * Confirmation for a destructive blob delete; shared by the viewer and the Media tab's long-press menu.
 * When [postCount] of your posts use the blob, Delete everywhere also offers [onConfirmWithPosts]
 * ("Delete file and post"), so no post is left showing a dead image. Wording matches iOS
 * `confirmMediaDelete` (DestructiveConfirmation.swift).
 */
@Composable
internal fun DeleteBlobConfirmDialog(
    scope: DeleteScope,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    postCount: Int = 0,
    onConfirmWithPosts: (() -> Unit)? = null,
) {
    val title: String
    val body: String
    val confirmLabel: String
    when (scope) {
        DeleteScope.MIRRORS -> {
            title = "Delete from mirrors?"
            body = "Removes this blob from all external Blossom mirrors. Your local copy is kept."
            confirmLabel = "Delete from mirrors"
        }
        DeleteScope.EVERYWHERE -> {
            title = "Delete everywhere?"
            body = "Permanently removes this blob from your local Blossom store and all external mirrors. This cannot be undone."
            confirmLabel = "Delete everywhere"
        }
    }
    val offerPosts = scope == DeleteScope.EVERYWHERE && postCount > 0 && onConfirmWithPosts != null
    val message = if (offerPosts) body + deleteBlobPostsNote(postCount) else body
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = {
            if (offerPosts && onConfirmWithPosts != null) {
                Column(horizontalAlignment = Alignment.End) {
                    TextButton(onClick = onConfirmWithPosts) {
                        Text(deleteBlobWithPostsLabel(postCount), color = Color(0xFFE53935))
                    }
                    TextButton(onClick = onConfirm) {
                        Text("Delete file only", color = Color(0xFFE53935))
                    }
                }
            } else {
                TextButton(onClick = onConfirm) {
                    Text(confirmLabel, color = Color(0xFFE53935))
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

/** iOS: "Delete file and post" / "Delete file and N posts". */
internal fun deleteBlobWithPostsLabel(postCount: Int): String =
    if (postCount == 1) "Delete file and post" else "Delete file and $postCount posts"

/** Appended to the Delete everywhere message when your posts use the blob (iOS wording). */
internal fun deleteBlobPostsNote(postCount: Int): String =
    if (postCount == 1) {
        " One of your posts uses it and will show a broken image unless you delete that post too." +
            " Deleting the post removes all of it: its text and any other photos in it."
    } else {
        " $postCount of your posts use it and will show a broken image unless you delete them too." +
            " Deleting a post removes all of it: its text and any other photos in it."
    }
