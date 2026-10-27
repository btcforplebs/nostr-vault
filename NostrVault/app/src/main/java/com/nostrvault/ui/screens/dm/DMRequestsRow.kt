package com.nostrvault.ui.screens.dm

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

/**
 * The one row above the inbox that holds messages from people outside your
 * Web of Trust you have never written to. iOS: the Requests row in DMInboxView.
 */
@Composable
internal fun DMRequestsRow(count: Int, onClick: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .background(SecondaryGroupedBg)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        Icon(NostrVaultIcons.DMs, contentDescription = null, tint = colors.primary, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text("Requests ($count)", color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Text("From people outside your Web of Trust", color = SecondaryText, fontSize = 12.sp)
        }
        Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = TertiaryText, modifier = Modifier.size(18.dp))
    }
}

/** Heads the Requests list, with the way back to the inbox. */
@Composable
internal fun DMRequestsHeader(onBack: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(SecondaryGroupedBg)
            .clickable(onClick = onBack)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Text("‹ Back to Messages", color = LocalNostrVaultColors.current.primary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(4.dp))
        Text(
            "Not shown in your inbox and never notified. Reply to move a conversation into your inbox.",
            color = SecondaryText,
            fontSize = 12.sp,
        )
    }
}
