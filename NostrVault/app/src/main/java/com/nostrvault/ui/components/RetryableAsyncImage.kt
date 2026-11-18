package com.nostrvault.ui.components

import androidx.compose.runtime.collectAsState
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import com.nostrvault.fips.meshAuthor
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.compose.AsyncImagePainter
import coil.request.ImageRequest
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.TertiaryText

/**
 * Image loader that displays a retry overlay on failure.
 * Matches iOS RetryableAsyncImage behaviour: shows icon + "Media Missing" + retry button.
 *
 * Retry works by incrementing a key parameter in the Coil ImageRequest,
 * forcing a fresh load without double-caching.
 */
@Composable
fun RetryableAsyncImage(
    model: Any?,
    contentDescription: String?,
    contentScale: ContentScale,
    modifier: Modifier = Modifier,
    meshAuthor: String? = null,
    /** The decoded picture's size, once it lands. */
    onLoaded: ((androidx.compose.ui.geometry.Size) -> Unit)? = null,
) {
    var retryKey by remember { mutableIntStateOf(0) }
    var loadState by remember { mutableStateOf<AsyncImagePainter.State>(AsyncImagePainter.State.Empty) }
    val context = LocalContext.current
    // Built once per picture and retry, not on every recomposition of the tile.
    val request = remember(context, model, retryKey, meshAuthor) {
        ImageRequest.Builder(context)
            .data(model)
            .setParameter("retry", retryKey, memoryCacheKey = null)
            .meshAuthor(meshAuthor)
            .crossfade(false) // Instant rendering from cache
            .build()
    }
    // Only this picture's mesh phase: a tile no longer recomposes when another
    // picture's phase changes, and a URL with no blob hash never listens at all.
    val meshPhase by rememberMeshPhase(model as? String)

    Box(modifier = modifier) {
        AsyncImage(
            model = request,
            contentDescription = contentDescription,
            contentScale = contentScale,
            onState = {
                loadState = it
                if (it is AsyncImagePainter.State.Success) onLoaded?.invoke(it.painter.intrinsicSize)
            },
            modifier = Modifier.fillMaxSize(),
        )

        if (meshPhase != null) {
            MeshMediaStatusOverlay(url = model as? String, compact = true, modifier = Modifier.matchParentSize())
        } else if ((loadState as? AsyncImagePainter.State.Error)?.result?.throwable is com.nostrvault.service.DMFileLoader.TooBig) {
            // A big locked DM photo isn't opened in the thread; tapping the tile opens it in the viewer.
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
                modifier = Modifier.align(Alignment.Center),
            ) {
                Icon(
                    imageVector = NostrVaultIcons.Media,
                    contentDescription = null,
                    tint = TertiaryText,
                    modifier = Modifier.size(36.dp),
                )
                Spacer(Modifier.height(8.dp))
                Text(text = "Large photo", color = SecondaryText, fontSize = 13.sp)
                Text(text = "Tap to open", color = TertiaryText, fontSize = 12.sp)
            }
        } else if (loadState is AsyncImagePainter.State.Error) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
                modifier = Modifier.align(Alignment.Center),
            ) {
                Icon(
                    imageVector = NostrVaultIcons.Media,
                    contentDescription = null,
                    tint = TertiaryText,
                    modifier = Modifier.size(36.dp),
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    text = "Media Missing",
                    color = SecondaryText,
                    fontSize = 13.sp,
                )
                Spacer(Modifier.height(12.dp))
                OutlinedButton(onClick = { retryKey++ }) {
                    Text("Try Again")
                }
            }
        }
    }
}

/** [url]'s mesh phase, recomposing only when that one phase changes. */
@Composable
private fun rememberMeshPhase(url: String?): State<com.nostrvault.fips.MeshMediaPhase?> {
    val hash = remember(url) { url?.let { com.nostrvault.fips.FipsMediaRouter.sha256In(it) } }
    if (hash == null) return remember { mutableStateOf(null) }
    val phases = com.nostrvault.fips.MeshMediaStatus.phases
    val flow = remember(hash) { phases.map { it[hash] }.distinctUntilChanged() }
    return flow.collectAsState(initial = phases.value[hash])
}
