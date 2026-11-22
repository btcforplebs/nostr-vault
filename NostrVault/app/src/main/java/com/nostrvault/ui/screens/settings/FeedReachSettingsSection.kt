package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedReach
import com.nostrvault.data.model.WebGate
import com.nostrvault.ui.theme.*

/**
 * Settings › Feed › Reach: how far each feed reaches past the people you
 * follow. iOS `FeedReachSettingsSection.swift`. "Your web" is the people in
 * your web of trust; "+ a few one hop out" lets in a rationed few followed
 * by some of your follows, too few to be in your web. Underrated starts
 * there; every other feed starts on your web.
 */
@Composable
fun FeedReachSettingsSection(
    settings: Map<String, String>,
    onChange: (FeedMode, WebGate.Reach) -> Unit,
) {
    Text(
        text = "Reach",
        color = SecondaryText,
        fontSize = 13.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(bottom = 8.dp),
    )
    Surface(shape = RoundedCornerShape(12.dp), color = SecondaryGroupedBg, modifier = Modifier.fillMaxWidth()) {
        Column {
            FeedReach.modes.forEachIndexed { i, mode ->
                if (i > 0) HorizontalDivider(color = TertiaryGroupedBg, thickness = 0.5.dp)
                ReachRow(mode, FeedReach.reach(mode, settings)) { onChange(mode, it) }
            }
        }
    }
    Text(
        text = "How far each feed reaches past the people you follow. One hop out shows at most one post per person " +
            "and a few per feed. Global's Everyone shield still opens Global to everyone.",
        color = TertiaryText,
        fontSize = 12.sp,
        modifier = Modifier.padding(start = 4.dp, top = 6.dp),
    )
}

/** One feed's row: its name, and a menu of the two reaches. */
@Composable
private fun ReachRow(mode: FeedMode, reach: WebGate.Reach, onPick: (WebGate.Reach) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp),
    ) {
        Text(mode.displayName, color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Box {
            TextButton(onClick = { open = true }) {
                Text(FeedReach.label(reach), color = LocalNostrVaultColors.current.primary, fontSize = 14.sp)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                for (choice in listOf(WebGate.Reach.WEB, WebGate.Reach.WEB_AND_LOOSE)) {
                    DropdownMenuItem(
                        text = { Text(FeedReach.label(choice)) },
                        onClick = { open = false; onPick(choice) },
                    )
                }
            }
        }
    }
}
