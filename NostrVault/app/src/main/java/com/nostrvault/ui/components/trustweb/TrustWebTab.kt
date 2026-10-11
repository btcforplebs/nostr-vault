package com.nostrvault.ui.components

import com.nostrvault.tutorials.TutorialCenter
import com.nostrvault.tutorials.TutorialID
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import com.nostrvault.data.model.TrustPath
import kotlinx.coroutines.flow.first

/**
 * The WOT tab: the globe with nobody picked. You sit at the core with your
 * follows around you and the rest of your web as the haze. Tapping a face
 * centres on them and shows how they reach you: the same globe a post's WOT
 * button opens, pointed back at you. Tapping the tab again ([reselects])
 * brings it back to you. Port of iOS WOTTabView.
 */
@Composable
fun TrustWebTab(
    onProfileClick: (String) -> Unit,
    /** The trust card's Message: opens a DM thread with them. */
    onMessage: (String) -> Unit,
    reselects: kotlinx.coroutines.flow.Flow<*>,
    /** The floating tab bar's height, so the footer's words sit above it. */
    bottomInset: androidx.compose.ui.unit.Dp,
) {
    val trust = rememberTrustPathServices().trustPathService()
    val me by trust.meUpdates.collectAsState()
    // The WoT tutorial points into the globe, and starts here the first
    // time the tab shows (after Fill your vault; see TutorialProgress).
    val tutorialRevision by TutorialCenter.revision.collectAsState()
    LaunchedEffect(me, tutorialRevision) {
        TutorialCenter.startIfEligible(TutorialID.WOT, me)
    }
    Box(Modifier.fillMaxSize().background(Color.Black).background(SpaceBrush)) {
        // A new account draws a new globe; the globe keeps up with your follows itself.
        if (me.isNotEmpty()) androidx.compose.runtime.key(me) {
            TrustWebContent(
                author = me,
                // The path from you to you: no bridges, nothing to look up.
                path = TrustPath.resolve(me, me, emptySet(), emptySet(), emptyList()),
                onProfileClick = onProfileClick,
                onDismiss = null,
                isWOTTab = true,
                onMessage = onMessage,
                reselects = reselects,
                bottomInset = bottomInset,
            )
        }
    }
}
