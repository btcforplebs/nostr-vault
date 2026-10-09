package com.nostrvault.ui.screens

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import com.nostrvault.ui.components.TrustWebTab
import com.nostrvault.ui.navigation.FloatingNavBarInset
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.navigation.TabReselect

/**
 * The WOT tab, in Media's old slot: the #426 trust globe centred on you with
 * nobody picked. Tapping someone shows how they reach you. Port of iOS
 * WOTTabView (#443).
 */
@Composable
fun WOTTabScreen(onProfileClick: (String) -> Unit, onMessage: (String) -> Unit) {
    // One flow for the screen's life: a new one each pass would restart its collector.
    val reselects = remember { TabReselect.of(Screen.WOT) }
    TrustWebTab(
        onProfileClick = onProfileClick,
        onMessage = onMessage,
        reselects = reselects,
        bottomInset = FloatingNavBarInset.height.value,
    )
}
