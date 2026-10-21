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
import com.nostrvault.data.model.GlobeArcs
import com.nostrvault.data.model.LiveArcsSetting
import com.nostrvault.ui.screens.dashboard.IconFilterButton

/**
 * The live arrivals switches, kept across launches with iOS's keys
 * ([LiveArcsSetting]): the antenna (the main switch), which feeds' notes fly,
 * and which sorts. The feed and sort switches live in My Web ([MyWebSheet]),
 * as on iOS.
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
