package com.nostrvault.ui.components

import android.content.Context
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.SettingsInputAntenna
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Hub
import androidx.compose.material.icons.outlined.People
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.GlobeArcs
import com.nostrvault.data.model.LiveArcsSetting
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.Surface1
import com.nostrvault.ui.screens.dashboard.IconFilterButton

/**
 * The live arrivals switches, kept across launches with iOS's keys
 * ([LiveArcsSetting]): the antenna (the main switch), which feeds' notes fly,
 * and which sorts. iOS keeps the feed and sort switches in its My Web dashboard;
 * Android has none yet, so they live in [LiveArcsSheet], opened from the WOT bar.
 */
@Stable
internal class LiveArcsState(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(LiveArcsSetting.PREFS, Context.MODE_PRIVATE)
    var on by mutableStateOf(LiveArcsSetting.isOn(prefs))
        private set
    var rings by mutableStateOf(LiveArcsSetting.rings(prefs))
        private set
    var show by mutableStateOf(LiveArcsSetting.show(prefs))
        private set

    fun switchOn(value: Boolean) {
        prefs.edit().putBoolean(LiveArcsSetting.KEY, value).apply()
        on = value
    }

    fun setRing(ring: GlobeArcs.Ring, value: Boolean) {
        prefs.edit().putBoolean(LiveArcsSetting.key(ring), value).apply()
        rings = LiveArcsSetting.rings(prefs)
    }

    fun setSort(sort: GlobeArcs.Sort, value: Boolean) {
        prefs.edit().putBoolean(LiveArcsSetting.key(sort), value).apply()
        show = LiveArcsSetting.show(prefs)
    }
}

@Composable
internal fun rememberLiveArcsState(): LiveArcsState {
    val context = LocalContext.current
    return remember { LiveArcsState(context) }
}

/** The bar's switch for live arrivals, like the feed's Auto-load. */
@Composable
internal fun LiveArcsToggle(state: LiveArcsState) {
    IconFilterButton(
        icon = Icons.Filled.SettingsInputAntenna,
        contentDescription = "Live arrivals",
        isSelected = state.on,
        onClick = { state.switchOn(!state.on) },
        modifier = Modifier.semantics { stateDescription = if (state.on) "On" else "Off" },
    )
}

/** Which feeds and sorts fly across the globe (iOS My Web's Live arrivals and "What flies" sections). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun LiveArcsSheet(state: LiveArcsState, onDismiss: () -> Unit) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Surface1,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SecondaryText) },
    ) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            Text("Live arrivals", color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
            SwitchRow(Icons.Filled.SettingsInputAntenna, "Live arrivals", "A star flies across the globe for each new note",
                state.on) { state.switchOn(it) }
            ListHeader("Feeds")
            SwitchRow(Icons.Outlined.People, GlobeArcs.Ring.FOLLOWING.title, "From the people you follow, on the ring",
                GlobeArcs.Ring.FOLLOWING in state.rings, enabled = state.on) { state.setRing(GlobeArcs.Ring.FOLLOWING, it) }
            SwitchRow(Icons.Outlined.Hub, GlobeArcs.Ring.DISCOVER.title, "From your wider web, the next shell out",
                GlobeArcs.Ring.DISCOVER in state.rings, enabled = state.on) { state.setRing(GlobeArcs.Ring.DISCOVER, it) }
            SwitchRow(Icons.Outlined.Public, GlobeArcs.Ring.GLOBAL.title, "From everyone else, the outer haze",
                GlobeArcs.Ring.GLOBAL in state.rings, enabled = state.on) { state.setRing(GlobeArcs.Ring.GLOBAL, it) }
            ListHeader("What flies")
            SwitchRow(Icons.Outlined.ChatBubbleOutline, "New notes", "A star for each new note",
                state.show.notes, enabled = state.on) { state.setSort(GlobeArcs.Sort.NOTE, it) }
            SwitchRow(Icons.AutoMirrored.Filled.Reply, "Replies", "A star from who replied to who they answered",
                state.show.replies, enabled = state.on) { state.setSort(GlobeArcs.Sort.REPLY, it) }
            SwitchRow(Icons.Filled.Repeat, "Reposts", "A star from who reposted to who wrote it",
                state.show.reposts, enabled = state.on) { state.setSort(GlobeArcs.Sort.REPOST, it) }
            SwitchRow(Icons.Filled.FavoriteBorder, "Reactions", "A smaller star from who reacted to who they reacted to",
                state.show.reactions, enabled = state.on) { state.setSort(GlobeArcs.Sort.REACTION, it) }
        }
    }
}

@Composable
private fun SwitchRow(
    icon: ImageVector,
    title: String,
    detail: String,
    checked: Boolean,
    enabled: Boolean = true,
    onChange: (Boolean) -> Unit,
) {
    val accent = LocalNostrVaultColors.current.primary
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
    ) {
        Icon(icon, contentDescription = null, tint = if (enabled) accent else SecondaryText, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = if (enabled) PrimaryText else SecondaryText, fontSize = 15.sp)
            Text(detail, color = SecondaryText, fontSize = 12.sp)
        }
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            enabled = enabled,
            colors = SwitchDefaults.colors(checkedTrackColor = accent),
        )
    }
}
