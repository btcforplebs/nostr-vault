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
