package com.nostrvault.ui.screens.dm

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.os.bundleOf
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.ui.components.PaneViewModelScope
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SeparatorColor
import com.nostrvault.ui.theme.WindowBackground

/** iOS DMInboxMetrics. */
internal object DMInboxMetrics {
    /** Below this the conversation column would be narrower than a phone's. */
    val minTwoPaneWidth = 700.dp
    val listWidth = 340.dp
}

/** Wide enough for the inbox and the open conversation side by side (iOS DMInboxView). */
internal fun dmUsesTwoPane(width: Dp): Boolean = width >= DMInboxMetrics.minTwoPaneWidth

/**
 * The inbox on a tablet or unfolded phone: the list on the left and the
 * picked conversation on the right. Nothing is opened for the reader: opening
 * a conversation marks it read, so picking one on their behalf would clear an
 * unread they haven't seen (iOS twoPaneView).
 */
@Composable
internal fun DMTwoPane(
    selected: String?,
    onProfileClick: (String) -> Unit,
    list: @Composable (Modifier) -> Unit,
) {
    Row(Modifier.fillMaxSize().background(WindowBackground)) {
        list(Modifier.width(DMInboxMetrics.listWidth).fillMaxHeight())
        VerticalDivider(color = SeparatorColor)
        Box(Modifier.weight(1f).fillMaxHeight()) {
            if (selected != null) {
                key(selected) { DMThreadPane(selected, onProfileClick) }
            } else {
                DMNoConversationSelected()
            }
        }
    }
}

/**
 * The thread in the right pane. Its view model reads the pubkey from saved
 * state, the way the pushed route hands it over (see [PaneViewModelScope]).
 */
@Composable
private fun DMThreadPane(pubkey: String, onProfileClick: (String) -> Unit) {
    PaneViewModelScope(pubkey, bundleOf("pubkey" to pubkey)) {
        DMThreadScreen(
            counterpartyPubkey = pubkey,
            onProfileClick = onProfileClick,
            onBack = null,
            viewModel = hiltViewModel(key = "dm-pane:$pubkey"),
        )
    }
}

/** iOS ContentUnavailableView in the right pane before a conversation is picked. */
@Composable
private fun DMNoConversationSelected() {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp)
            .semantics(mergeDescendants = true) {},
    ) {
        Icon(
            imageVector = NostrVaultIcons.DMs,
            contentDescription = null,
            tint = SecondaryText,
            modifier = Modifier.size(44.dp).padding(bottom = 4.dp),
        )
        Text(
            text = "No Conversation Selected",
            color = PrimaryText,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center,
        )
        Text(
            text = "Pick a conversation to read it here.",
            color = SecondaryText,
            fontSize = 15.sp,
            textAlign = TextAlign.Center,
        )
    }
}
