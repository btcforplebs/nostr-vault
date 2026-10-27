package com.nostrvault.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.SecondaryText

/**
 * Under the attachments: where they will be uploaded, and the way to the
 * media server settings to change that.
 */
@Composable
internal fun UploadServersLink(servers: List<String>, onOpen: () -> Unit, modifier: Modifier = Modifier) {
    val accent = LocalNostrVaultColors.current.primary
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clickable(role = Role.Button, onClickLabel = "Open media servers", onClick = onOpen)
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            uploadServersSummary(servers),
            color = SecondaryText,
            fontSize = 13.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        Text(
            if (servers.isEmpty()) "  Add a server" else "  Media servers",
            color = accent,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
    }
}

/** "Uploads to blossom.primal.net and 2 more", from the server URLs. */
internal fun uploadServersSummary(servers: List<String>): String {
    if (servers.isEmpty()) return "No media server set"
    val first = runCatching { java.net.URI(servers[0].trim()).host }.getOrNull() ?: servers[0]
    val more = servers.size - 1
    return if (more == 0) "Uploads to $first" else "Uploads to $first and $more more"
}
