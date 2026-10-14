package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

/**
 * Takes the place of the note you opened once you block its author; their
 * replies and quotes go with it. iOS: NoteDetailView.blockedNotePlaceholder.
 */
@Composable
internal fun BlockedNotePlaceholder(modifier: Modifier = Modifier) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
        modifier = modifier
            .fillMaxWidth()
            .background(SecondaryGroupedBg, RoundedCornerShape(12.dp))
            .padding(vertical = 24.dp),
    ) {
        Icon(NostrVaultIcons.Blocked, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text("You blocked this person", color = SecondaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}
