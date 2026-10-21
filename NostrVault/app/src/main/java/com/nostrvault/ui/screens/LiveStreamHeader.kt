package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.LiveStream
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.NostrWebLinks
import com.nostrvault.ui.theme.*

/**
 * The player's header: the title, then one row of the host's avatar, name,
 * viewer count and the ⋯ menu with the web link and the report and block
 * affordances any surface showing third-party video needs.
 * iOS: LiveStreamPlayerView.header.
 */
@Composable
internal fun LiveStreamHeader(
    stream: LiveStream,
    hostName: String,
    hostPictureUrl: String?,
    onReport: () -> Unit,
    onBlock: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    var showMenu by remember { mutableStateOf(false) }
    Column(
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Text(
            text = stream.title ?: "Untitled stream",
            color = PrimaryText,
            fontSize = 16.sp,
            fontWeight = FontWeight.Bold,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            AvatarImage(url = hostPictureUrl, pubkey = stream.hostPubkey, size = 24.dp, displayName = hostName)
            Text(
                text = hostName,
                color = PrimaryText,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            stream.participants?.let {
                Text("· $it watching", color = SecondaryText, fontSize = 11.sp, maxLines = 1)
            }
            Spacer(Modifier.weight(1f))
            Box {
                IconButton(onClick = { showMenu = true }, modifier = Modifier.size(28.dp)) {
                    Icon(Icons.Filled.MoreHoriz, contentDescription = "More", tint = colors.primary)
                }
                DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
                    NostrWebLinks.forStream(stream)?.let { link ->
                        DropdownMenuItem(
                            text = { Text(link.label) },
                            leadingIcon = { Icon(NostrVaultIcons.OpenExternal, contentDescription = null) },
                            onClick = {
                                showMenu = false
                                NostrWebLinks.open(context, link.url)
                            },
                        )
                        HorizontalDivider()
                    }
                    DropdownMenuItem(
                        text = { Text("Report stream") },
                        leadingIcon = { Icon(NostrVaultIcons.Alert, contentDescription = null) },
                        onClick = {
                            showMenu = false
                            onReport()
                        },
                    )
                    DropdownMenuItem(
                        text = { Text("Block host", color = ErrorRed) },
                        leadingIcon = { Icon(NostrVaultIcons.Blocked, contentDescription = null, tint = ErrorRed) },
                        onClick = {
                            showMenu = false
                            onBlock()
                        },
                    )
                }
            }
        }
    }
}
