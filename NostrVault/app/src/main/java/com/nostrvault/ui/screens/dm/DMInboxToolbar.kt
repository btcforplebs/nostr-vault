package com.nostrvault.ui.screens.dm

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.HiddenTitle
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/**
 * The Messages header (Logen 2026-11-03, c2bba1de): no title text (read out only, so the buttons have room),
 * then Search, Requests (a tray with the count, only while there are any), Mark all read and New Message.
 */
@Composable
internal fun DMInboxToolbar(
    requestCount: Int,
    inRequests: Boolean,
    searching: Boolean,
    onToggleRequests: () -> Unit,
    onToggleSearch: () -> Unit,
    onMarkAllRead: () -> Unit,
    onNewMessage: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        HiddenTitle(if (inRequests) "Message requests" else "Messages")
        Spacer(Modifier.weight(1f))
        GlassPill {
            IconButton(onClick = onToggleSearch, modifier = Modifier.size(40.dp)) {
                Icon(
                    NostrVaultIcons.Search,
                    contentDescription = if (searching) "Close search" else "Search messages",
                    tint = if (searching) colors.primary else SecondaryText,
                    modifier = Modifier.size(24.dp),
                )
            }
            if (requestCount > 0 || inRequests) {
                IconButton(onClick = onToggleRequests, modifier = Modifier.size(40.dp)) {
                    BadgedBox(badge = { if (requestCount > 0) Badge { Text("$requestCount", fontSize = 10.sp) } }) {
                        Icon(
                            NostrVaultIcons.Activity,
                            contentDescription = if (inRequests) "Back to Messages" else "Requests, $requestCount",
                            tint = if (inRequests) colors.primary else SecondaryText,
                            modifier = Modifier.size(24.dp),
                        )
                    }
                }
            }
            IconButton(onClick = onMarkAllRead, modifier = Modifier.size(40.dp)) {
                Icon(NostrVaultIcons.MarkAllRead, "Mark all read", tint = colors.primary, modifier = Modifier.size(25.dp))
            }
            IconButton(onClick = onNewMessage, modifier = Modifier.size(40.dp)) {
                Icon(NostrVaultIcons.Edit, "New Message", tint = colors.primary, modifier = Modifier.size(25.dp))
            }
        }
    }
}

/** The search box under the header: names and message text, searched on this device only (DMInboxSearch). */
@Composable
internal fun DMInboxSearchField(query: String, onQueryChange: (String) -> Unit) {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    OutlinedTextField(
        value = query,
        onValueChange = onQueryChange,
        singleLine = true,
        placeholder = { Text("Search names and messages", color = SecondaryText) },
        leadingIcon = { Icon(NostrVaultIcons.Search, contentDescription = null, tint = SecondaryText) },
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        shape = RoundedCornerShape(12.dp),
        colors = OutlinedTextFieldDefaults.colors(focusedTextColor = PrimaryText, unfocusedTextColor = PrimaryText),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 6.dp)
            .focusRequester(focus),
    )
}
