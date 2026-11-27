package com.nostrvault.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SecondaryText

/** "12 from outside your web" (iOS `VaultActivity.outsideLabel`). */
internal fun outsideLabel(count: Int): String = "$count from outside your web"

/**
 * People and notes from outside your web, folded under one line until asked
 * for (Logen 2026-11-13 option B; search plan D4). Follows the Users / Notes
 * tab picked: [people] and [notes] are already narrowed to it. iOS twin:
 * `SearchView+Outside.swift`; web: `components/OutsideFold.jsx`.
 */
internal fun LazyListScope.searchOutsideFold(
    people: List<FeedProfile>,
    notes: List<FeedNote>,
    open: Boolean,
    onToggle: () -> Unit,
    personRow: @Composable (FeedProfile, Modifier) -> Unit,
    noteCard: @Composable (FeedNote) -> Unit,
) {
    val count = people.size + notes.size
    if (count == 0) return
    item(key = "outside-fold") { OutsideFoldLine(count, open, onToggle) }
    if (!open) return
    itemsIndexed(people, key = { _, it -> "outside-p-${it.pubkey}" }) { i, profile ->
        personRow(profile, Modifier.searchSectionRow(last = i == people.lastIndex && notes.isEmpty()))
    }
    items(notes, key = { "outside-n-${it.id}" }) { note -> noteCard(note) }
}

@Composable
private fun OutsideFoldLine(count: Int, open: Boolean, onToggle: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onToggle)
            .semantics { stateDescription = if (open) "Shown" else "Hidden" }
            .padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        Icon(NostrVaultIcons.OutsideNetwork, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(16.dp))
        Text(
            "${if (open) "Hide" else "Show"} ${outsideLabel(count)}",
            color = SecondaryText,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.weight(1f))
        Icon(
            if (open) NostrVaultIcons.ChevronUp else NostrVaultIcons.ChevronDown,
            contentDescription = null,
            tint = SecondaryText,
            modifier = Modifier.size(16.dp),
        )
    }
}
