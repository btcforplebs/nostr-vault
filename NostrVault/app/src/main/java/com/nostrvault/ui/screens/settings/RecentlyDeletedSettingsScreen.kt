package com.nostrvault.ui.screens.settings

import android.text.format.DateUtils
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.data.model.FeedNote
import com.nostrvault.service.deleted.DeletedPost
import com.nostrvault.ui.components.DestructiveConfirmDialog
import com.nostrvault.ui.components.RetryableAsyncImage
import com.nostrvault.ui.theme.*

/**
 * Settings > Recently Deleted: your posts deleted from this device in the
 * last 30 days, each with Un-delete and Delete forever. Port of iOS
 * RecentlyDeletedSettingsView.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecentlyDeletedSettingsScreen(
    onBack: () -> Unit,
    viewModel: RecentlyDeletedSettingsViewModel = hiltViewModel(),
) {
    val posts by viewModel.posts.collectAsState()
    val restoringId by viewModel.restoringId.collectAsState()
    val message by viewModel.message.collectAsState()
    var pendingForget by remember { mutableStateOf<DeletedPost?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Recently Deleted") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
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
        ) {
            message?.let {
                Text(it, color = SecondaryText, fontSize = 13.sp, modifier = Modifier.padding(bottom = 12.dp))
            }
            if (posts.isEmpty()) {
                Text("No deleted posts.", color = TertiaryText, fontSize = 14.sp, modifier = Modifier.padding(vertical = 4.dp))
            } else {
                posts.forEach { post ->
                    DeletedPostRow(
                        post = post,
                        restoring = restoringId == post.id,
                        busy = restoringId != null,
                        onUndelete = { viewModel.undelete(post) },
                        onDeleteForever = { pendingForget = post },
                    )
                    HorizontalDivider(color = SecondaryText.copy(alpha = 0.2f))
                }
            }
            Text(
                text = "Posts you delete on this device stay here for 30 days. ${DeletedPost.UNDELETE_NOTE}",
                color = SecondaryText,
                fontSize = 12.sp,
                modifier = Modifier.padding(top = 12.dp),
            )
            Spacer(Modifier.height(32.dp))
        }
    }

    pendingForget?.let { post ->
        DestructiveConfirmDialog(
            title = "Delete Forever",
            consequence = "This removes the saved copy. You won't be able to un-delete this post.",
            confirmLabel = "Delete Forever",
            onConfirm = {
                viewModel.deleteForever(post)
                pendingForget = null
            },
            onDismiss = { pendingForget = null },
        )
    }
}

@Composable
private fun DeletedPostRow(
    post: DeletedPost,
    restoring: Boolean,
    busy: Boolean,
    onUndelete: () -> Unit,
    onDeleteForever: () -> Unit,
) {
    val images = remember(post.id) { imageUrls(post) }
    val text = remember(post.id) {
        images.fold(post.content) { acc, url -> acc.replace(url, "") }.trim()
    }
    Column(modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
        if (text.isNotEmpty()) {
            Text(text, color = PrimaryText, fontSize = 15.sp, maxLines = 4, overflow = TextOverflow.Ellipsis)
        }
        if (images.isNotEmpty()) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.padding(top = 8.dp).horizontalScroll(rememberScrollState()),
            ) {
                images.forEach { url ->
                    RetryableAsyncImage(
                        model = url,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.size(64.dp).clip(RoundedCornerShape(6.dp)),
                    )
                }
            }
        }
        Text(
            "Deleted " + DateUtils.getRelativeTimeSpanString(post.deletedAt).toString().lowercase(),
            color = SecondaryText,
            fontSize = 12.sp,
            modifier = Modifier.padding(top = 6.dp),
        )
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 6.dp)) {
            Button(onClick = onUndelete, enabled = !busy) {
                if (restoring) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                } else {
                    Text("Un-delete")
                }
            }
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onDeleteForever, enabled = !busy) {
                Text("Delete Forever", color = ErrorRed)
            }
        }
    }
}

private val IMAGE_EXTENSION = Regex("""\.(jpe?g|png|gif|webp|heic|avif)(\?.*)?$""", RegexOption.IGNORE_CASE)

/** The post's image links: by file extension, or an `imeta` with an image type. */
private fun imageUrls(post: DeletedPost): List<String> {
    val imetaImages = post.tags
        .filter { it.firstOrNull() == "imeta" && it.any { part -> part.startsWith("m image/") } }
        .mapNotNull { tag -> tag.firstOrNull { it.startsWith("url ") }?.removePrefix("url ") }
        .toSet()
    val note = FeedNote.fromEvent(post.id, post.pubkey, post.content, post.tags, post.createdAt, post.kind)
    return note.mediaURLs.filter { it in imetaImages || IMAGE_EXTENSION.containsMatchIn(it) }
}
