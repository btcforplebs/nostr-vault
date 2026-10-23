package com.nostrvault.ui.components

import androidx.compose.runtime.collectAsState
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
) {
    var retryKey by remember { mutableIntStateOf(0) }
    var loadState by remember { mutableStateOf<AsyncImagePainter.State>(AsyncImagePainter.State.Empty) }
    val context = LocalContext.current

    Box(modifier = modifier) {
        AsyncImage(
            model = ImageRequest.Builder(context)
                .data(model)
                .setParameter("retry", retryKey, memoryCacheKey = null)
                .meshAuthor(meshAuthor)
                .crossfade(false) // Instant rendering from cache
                .build(),
            contentDescription = contentDescription,
            contentScale = contentScale,
            onState = { loadState = it },
            modifier = Modifier.fillMaxSize(),
        )

        val meshPhases by com.nostrvault.fips.MeshMediaStatus.phases.collectAsState()
        val meshPhase = com.nostrvault.fips.MeshMediaStatus.phaseFor(meshPhases, model as? String)
        if (meshPhase != null) {
            MeshMediaStatusOverlay(url = model as? String, compact = true, modifier = Modifier.matchParentSize())
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
