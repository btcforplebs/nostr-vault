package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText

@Composable
internal fun SortMenu(sort: FollowListSort, onPick: (FollowListSort) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(
            onClick = { open = true },
            modifier = Modifier.size(48.dp).semantics { contentDescription = "Sort, ${sort.title}" },
        ) {
            Icon(NostrVaultIcons.Sort, null, tint = PrimaryText, modifier = Modifier.size(22.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            FollowListSort.entries.forEach { option ->
                DropdownMenuItem(
                    text = { Text(option.title) },
                    leadingIcon = {
                        if (option == sort) Icon(NostrVaultIcons.Check, null, modifier = Modifier.size(18.dp))
                        else Spacer(Modifier.size(18.dp))
                    },
                    onClick = { open = false; onPick(option) },
                )
            }
        }
    }
}
