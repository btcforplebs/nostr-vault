package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

/**
 * Above a reply whose parent no relay had: says so, so the reply isn't
 * read as the start of the conversation. Styled like [InlineLoadingRow].
 */
@Composable
internal fun ParentNotFoundRow() {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 16.dp),
    ) {
        Icon(
            imageVector = NostrVaultIcons.Reply,
            contentDescription = null,
            tint = SecondaryText,
            modifier = Modifier.size(14.dp),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            text = "The post this replies to wasn't found",
            color = SecondaryText,
            fontSize = 12.sp,
            fontWeight = androidx.compose.ui.text.font.FontWeight.Medium,
            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
        )
    }
}
