package com.nostrvault.ui.screens.dm

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

/**
 * Ends the inbox when a muted word hides conversations (DMMutes): how many,
 * and a tap shows them until the app restarts; tapped again, they hide.
 */
@Composable
internal fun DMMutedRow(count: Int, showing: Boolean, onToggle: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onToggle)
            .padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        Text(
            if (showing) "Hide conversations with muted words"
            else if (count == 1) "1 hidden: muted word" else "$count hidden: muted word",
            color = LocalNostrVaultColors.current.primaryText,
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(2.dp))
        Text(
            if (showing) "They're back in the list above." else "A message in each has a word you muted. Tap to show.",
            color = SecondaryText,
            fontSize = 12.sp,
        )
    }
}
