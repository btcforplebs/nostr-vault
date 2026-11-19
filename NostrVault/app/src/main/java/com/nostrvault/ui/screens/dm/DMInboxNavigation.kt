package com.nostrvault.ui.screens.dm

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/** What system Back does on the Messages list (B10, NV_MESSAGES_UX_CHECK 2026-11-18). */
internal enum class DMInboxBack {
    /** Close the search box first. */
    CLOSE_SEARCH,
    /** Then leave Requests for the inbox. */
    CLOSE_REQUESTS,
    /** Nothing open: Back leaves Messages as usual. */
    LEAVE;

    companion object {
        fun of(searching: Boolean, inRequests: Boolean): DMInboxBack = when {
            searching -> CLOSE_SEARCH
            inRequests -> CLOSE_REQUESTS
            else -> LEAVE
        }
    }
}

/**
 * True when the inbox has nothing but there are requests (B7): the list was
 * blank, with only the header's tray to find them by.
 */
internal fun dmInboxOnlyRequests(inboxEmpty: Boolean, requestCount: Int, inRequests: Boolean, searching: Boolean): Boolean =
    inboxEmpty && requestCount > 0 && !inRequests && !searching

/** "1 message request" / "3 message requests". */
internal fun dmRequestsLine(count: Int): String =
    if (count == 1) "1 message request is waiting" else "$count message requests are waiting"

/** The inbox is empty but requests are waiting: say so, and open them from here. Scrolls so pull-to-refresh works. */
@Composable
internal fun DMRequestsOnlyNotice(count: Int, onShowRequests: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    BoxWithConstraints(Modifier.fillMaxSize()) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .fillMaxWidth()
                .heightIn(min = maxHeight)
                .padding(horizontal = 24.dp),
        ) {
            Text("No messages from your web yet", color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
            Text(
                "${dmRequestsLine(count)}, from people outside your web.",
                color = SecondaryText,
                fontSize = 14.sp,
                textAlign = TextAlign.Center,
            )
            TextButton(onClick = onShowRequests) {
                Text("Show requests", color = colors.primary, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}
