package com.nostrvault.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BrokenImage
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.SecondaryText
import java.net.URI

/**
 * Whether a note photo's link is the owner's vault itself — a NIP-F1 `.fips`
 * name, which only the mesh reaches — rather than an ordinary https server.
 * A vault link that fails says "Couldn't reach the owner's vault"; anything
 * else is a plain broken image. Same rule as iOS `MediaVaultLink` and the
 * web's `afterMeshFail`.
 */
object MediaVaultLink {
    const val UNREACHED_TEXT = "Couldn't reach the owner's vault"

    fun isVault(url: String): Boolean {
        val host = try { URI(url.trim()).host } catch (_: Exception) { null } ?: return false
        val h = host.lowercase()
        return h.endsWith(".fips") || h.endsWith(".fips.")
    }
}

internal const val MEDIA_UNAVAILABLE_TEXT = "Media unavailable"

/** What a photo shows when it could not be loaded (iOS `MediaFailedPlaceholder`). */
@Composable
internal fun MediaFailedPlaceholder(url: String, compact: Boolean = false, modifier: Modifier = Modifier) {
    val vault = MediaVaultLink.isVault(url)
    // A blossom: link no server had the right bytes for (iOS and web say the same).
    val blossom = com.nostrvault.data.model.BlossomUri.isUri(url)
    val label = when {
        vault -> MediaVaultLink.UNREACHED_TEXT
        blossom -> MEDIA_UNAVAILABLE_TEXT
        else -> "Image unavailable"
    }
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically),
        modifier = modifier.fillMaxSize().padding(12.dp).semantics { contentDescription = label },
    ) {
        Icon(
            imageVector = if (vault) Icons.Outlined.CloudOff else Icons.Outlined.BrokenImage,
            contentDescription = null,
            tint = SecondaryText,
            modifier = Modifier.size(if (compact) 20.dp else 28.dp),
        )
        if ((vault || blossom) && !compact) {
            Text(label, color = SecondaryText, fontSize = 13.sp, textAlign = TextAlign.Center)
        }
    }
}
