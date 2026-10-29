package com.nostrvault.ui.screens.live

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.nostrvault.data.gif.GifCache
import com.nostrvault.data.gif.NostrBuildGifs
import com.nostrvault.ui.components.GifPickerSheet
import com.nostrvault.ui.screens.BlossomMediaItem
import com.nostrvault.ui.screens.BlossomMediaPickerSheet
import com.nostrvault.ui.screens.blossomShareLink
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The chat's media button: a photo or video from the phone, put on your media
 * servers; a GIF (its nostr.build link, or a copy on your servers when "Save to
 * my Blossom" is on, as in the composer); or something already in your Vault.
 * Each ends as a link handed to [onLink], which goes into the message box.
 */
@Composable
internal fun LiveChatMediaButton(
    uploading: Boolean,
    onBeforeOpen: () -> Unit,
    onLink: (String) -> Unit,
    upload: (Uri) -> Unit,
    /** A GIF the app downloaded: its type, and the file to delete after. */
    uploadFile: (java.io.File, String) -> Unit,
    saveGifsToBlossom: Boolean,
    onSaveGifsToBlossomChange: (Boolean) -> Unit,
    onError: (String) -> Unit,
    loadVaultItems: suspend () -> List<BlossomMediaItem>,
) {
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    var gifs by remember { mutableStateOf(false) }
    var vault by remember { mutableStateOf(false) }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri?.let(upload)
    }

    Box {
        IconButton(
            enabled = !uploading,
            onClick = {
                onBeforeOpen()
                menu = true
            },
        ) {
            if (uploading) {
                CircularProgressIndicator(color = colors.primary, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
            } else {
                Icon(NostrVaultIcons.Media, contentDescription = "Add a photo, video or GIF", tint = colors.primary)
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
                text = { Text("Photo or video") },
                leadingIcon = { Icon(NostrVaultIcons.Media, contentDescription = null) },
                onClick = {
                    menu = false
                    pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                },
            )
            DropdownMenuItem(
                text = { Text("GIF") },
                leadingIcon = { Icon(NostrVaultIcons.Gif, contentDescription = null) },
                onClick = {
                    menu = false
                    gifs = true
                },
            )
            DropdownMenuItem(
                text = { Text("From your Vault") },
                leadingIcon = { Icon(NostrVaultIcons.Blossom, contentDescription = null) },
                onClick = {
                    menu = false
                    vault = true
                },
            )
        }
    }

    if (gifs) {
        GifPickerSheet(
            onPick = { gif ->
                gifs = false
                if (!saveGifsToBlossom) {
                    onLink(gif.url)
                } else {
                    scope.launch {
                        try {
                            val (file, mime) = withContext(Dispatchers.IO) {
                                val (bytes, mime) = NostrBuildGifs.download(gif.url)
                                GifCache.newFile(context.cacheDir, mime).apply { writeBytes(bytes) } to mime
                            }
                            uploadFile(file, mime)
                        } catch (e: Exception) {
                            onError("Couldn't fetch that GIF: ${e.message ?: "unknown error"}")
                        }
                    }
                }
            },
            onDismiss = { gifs = false },
            saveToBlossom = saveGifsToBlossom,
            onSaveToBlossomChange = onSaveGifsToBlossomChange,
        )
    }
    if (vault) {
        BlossomMediaPickerSheet(
            onDismiss = { vault = false },
            onSelect = { item ->
                vault = false
                onLink(blossomShareLink(item))
            },
            loadItems = loadVaultItems,
        )
    }
}
