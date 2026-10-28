package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.SuggestedMediaServers
import com.nostrvault.ui.theme.*

/**
 * Media Servers › Suggested: known-good Blossom servers the user hasn't added
 * yet, each with an Add button. Hidden once every one is in the list.
 * iOS twin: `SuggestedMediaServersSection.swift`.
 */
@Composable
fun SuggestedMediaServersSection(
    servers: List<String>,
    onAdd: (String) -> Unit,
) {
    val suggestions = SuggestedMediaServers.notYetAdded(servers)
    if (suggestions.isEmpty()) return
    Column(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = "SUGGESTED",
            color = SecondaryText,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.sp,
            modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 8.dp),
        )
        suggestions.forEach { server ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 16.dp, end = 8.dp, top = 4.dp, bottom = 4.dp),
            ) {
                Icon(
                    imageVector = NostrVaultIcons.Blossom,
                    contentDescription = null,
                    tint = SecondaryText,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(server.host, color = PrimaryText, fontSize = 15.sp)
                    Text(server.note, color = SecondaryText, fontSize = 12.sp)
                }
                TextButton(
                    onClick = { onAdd(server.url) },
                    modifier = Modifier.semantics { contentDescription = "Add ${server.host}" },
                ) {
                    Text("Add", color = LocalNostrVaultColors.current.primary)
                }
            }
            HorizontalDivider(
                color = SeparatorColor,
                thickness = 0.5.dp,
                modifier = Modifier.padding(start = 16.dp),
            )
        }
        Text(
            text = "Servers other Nostr apps use. Prices and limits are set by each server and can change.",
            color = SecondaryText,
            fontSize = 12.sp,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
}
