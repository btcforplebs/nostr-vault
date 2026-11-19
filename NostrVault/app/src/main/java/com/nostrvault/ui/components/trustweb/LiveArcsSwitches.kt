package com.nostrvault.ui.components

import android.content.Context
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.SettingsInputAntenna
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import com.nostrvault.data.model.LiveArcsSetting
import com.nostrvault.ui.screens.dashboard.IconFilterButton

/**
 * Live stars, kept across launches with iOS's keys ([LiveArcsSetting]): the
 * bar's antenna and My Web's "Live stars" are one switch; My Web also has
 * Friends of friends and Likes, reposts and zaps (Logen 11/19).
 */
@Stable
internal class LiveArcsState(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(LiveArcsSetting.PREFS, Context.MODE_PRIVATE)
        .also(LiveArcsSetting::retireCutSwitches)
    var on by mutableStateOf(LiveArcsSetting.isOn(prefs))
        private set
    var show by mutableStateOf(LiveArcsSetting.show(prefs))
        private set

    fun switchOn(value: Boolean) {
        prefs.edit().putBoolean(LiveArcsSetting.KEY, value).apply()
        on = value
    }

    fun switchFriendsOfFriends(value: Boolean) {
        prefs.edit().putBoolean(LiveArcsSetting.FRIENDS_KEY, value).apply()
        show = show.copy(friendsOfFriends = value)
    }

    fun switchExtras(value: Boolean) {
        prefs.edit().putBoolean(LiveArcsSetting.EXTRAS_KEY, value).apply()
        show = show.copy(extras = value)
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
