package com.nostrvault.ui.components

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.staggeredgrid.LazyVerticalStaggeredGrid
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridCells
import androidx.compose.foundation.lazy.staggeredgrid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.data.gif.NostrBuildGif
import com.nostrvault.data.gif.NostrBuildGifs
import com.nostrvault.ui.theme.SecondaryText
import kotlinx.coroutines.launch

/**
 * GIF picker backed by the official nostr.build GIF API. Search, tap a GIF,
 * and its nostr.build link goes into the note (the API's terms: link the GIF
 * where it is, never re-host it). Shows the required "GIFs from nostr.build"
 * attribution. iOS: GifPickerSheet.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GifPickerSheet(onPick: (NostrBuildGif) -> Unit, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    val ctx = LocalContext.current
    var query by remember { mutableStateOf("") }
    var searched by remember { mutableStateOf("") }
    var gifs by remember { mutableStateOf<List<NostrBuildGif>>(emptyList()) }
    var page by remember { mutableStateOf(0) }
    var loading by remember { mutableStateOf(false) }
    var reachedEnd by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    fun run(next: Boolean) {
        val term = query.trim()
        if (term.isEmpty() || loading) return
        val p = if (next) page + 1 else 0
        loading = true; error = null
        scope.launch {
            try {
                val found = NostrBuildGifs.search(term, p)
                gifs = if (next) (gifs + found).distinctBy { it.id } else found
                page = p; searched = term
                reachedEnd = found.size < NostrBuildGifs.PAGE_SIZE
            } catch (e: Exception) {
                error = e.message ?: "Couldn't reach nostr.build"
            } finally {
                loading = false
            }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Color(0xFF151518)) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.85f).padding(horizontal = 12.dp)) {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                placeholder = { Text("Search GIFs, then press search") },
                leadingIcon = { Icon(Icons.Filled.Search, null) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { run(next = false) }),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                text = "GIFs from nostr.build",
                color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(vertical = 8.dp)
                    .clickable { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://nostr.build"))) },
            )
            when {
                error != null -> Text(error!!, color = SecondaryText, fontSize = 14.sp, modifier = Modifier.padding(16.dp))
                !loading && searched.isNotEmpty() && gifs.isEmpty() ->
                    Text("No GIFs found for “$searched”", color = SecondaryText, fontSize = 14.sp, modifier = Modifier.padding(16.dp))
            }
            LazyVerticalStaggeredGrid(
                columns = StaggeredGridCells.Adaptive(140.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalItemSpacing = 6.dp,
                modifier = Modifier.weight(1f),
            ) {
                items(gifs, key = { it.id }) { gif ->
                    AsyncImage(
                        model = gif.previewUrl,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .fillMaxWidth()
                            .aspectRatio(gif.aspectRatio)
                            .clip(RoundedCornerShape(8.dp))
                            .background(Color.White.copy(alpha = 0.06f))
                            .clickable { onPick(gif) }
                            .semantics { contentDescription = gif.title.ifBlank { "GIF from nostr.build" } },
                    )
                }
                if (gifs.isNotEmpty() && !reachedEnd && page < 4) {
                    item {
                        TextButton(onClick = { run(next = true) }, enabled = !loading) { Text("Show more GIFs") }
                    }
                }
            }
            if (loading) Box(Modifier.fillMaxWidth().padding(8.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(Modifier.size(24.dp))
            }
        }
    }
}
