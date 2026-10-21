package com.nostrvault.ui.screens.dm

import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.TertiaryText

/**
 * The thread's photo button: tap picks a photo, press and hold offers
 * "Paste Photo" for one copied in another app without a keyboard to paste it
 * from (iOS DMThreadView's contextMenu on the photo button).
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun DMPhotoButton(
    enabled: Boolean,
    onPick: () -> Unit,
    onPaste: (Uri) -> Unit,
    onNoPhoto: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    var menu by remember { mutableStateOf(false) }
    Box {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(48.dp)
                .clip(CircleShape)
                .combinedClickable(
                    enabled = enabled,
                    role = Role.Button,
                    onClickLabel = "Attach image",
                    onLongClickLabel = "Paste photo",
                    onClick = onPick,
                    onLongClick = { menu = true },
                ),
        ) {
            Icon(
                imageVector = NostrVaultIcons.Media,
                contentDescription = "Attach image",
                tint = if (enabled) colors.primary else TertiaryText,
            )
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
                text = { Text("Paste Photo") },
                leadingIcon = { Icon(Icons.Filled.ContentPaste, contentDescription = null) },
                enabled = enabled,
                onClick = {
                    menu = false
                    clipboardPhoto(context)?.let(onPaste) ?: onNoPhoto()
                },
            )
        }
    }
}

/** The first photo on the clipboard, or null when it holds none. */
private fun clipboardPhoto(context: Context): Uri? {
    val clip = context.getSystemService(ClipboardManager::class.java)?.primaryClip ?: return null
    val uris = (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }
    return DMPastedImage.firstPhoto(uris) { context.contentResolver.getType(it) }
}
