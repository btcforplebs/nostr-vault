package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.TrustMapOuter
import com.nostrvault.service.DiscoveryReachStore
import com.nostrvault.service.TrustMapOuterWatch
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent

@EntryPoint
@InstallIn(SingletonComponent::class)
interface GlobeOuterRingsEntryPoint {
    fun trustMapOuterWatch(): TrustMapOuterWatch
    fun discoveryReachStore(): DiscoveryReachStore
}

/** The rings for your own globe, kept up to date ([TrustMapOuterWatch]). */
@Composable
internal fun rememberTrustMapOuter(): TrustMapOuter {
    val context = LocalContext.current
    val watch = remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, GlobeOuterRingsEntryPoint::class.java).trustMapOuterWatch()
    }
    val outer by watch.outer.collectAsState()
    return outer
}

/**
 * Under your own globe on the WOT tab: what the outer rings are. With a rank,
 * "Found by your desktop Vault" and one chip per ring, each opening that ring
 * as a community ([OuterRingSheet]). A paired desktop Vault that has not
 * ranked yet says so. With no desktop Vault, the invite ([HavenInviteCard])
 * until "Not now". iOS `Views/TrustWeb/GlobeOuterRingsBar.swift`.
 */
@Composable
internal fun GlobeOuterRingsBar(
    accent: Color,
    profiles: Map<String, FeedProfile>,
    onNeedProfiles: (List<String>) -> Unit,
    onPick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val reach = remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, GlobeOuterRingsEntryPoint::class.java).discoveryReachStore()
    }
    val outer = rememberTrustMapOuter()
    val copy by reach.copy.collectAsState()
    val inviteHidden by HavenInviteSetting.hidden(context).collectAsState()
    var open by remember { mutableStateOf<TrustMapOuter.Ring?>(null) }
    val pill = Modifier.background(Color(0xCC1C1C22), CircleShape).border(1.dp, Color.White.copy(alpha = 0.14f), CircleShape)
    when {
        outer.source == TrustMapOuter.Source.RANKED && outer.rings.isNotEmpty() -> Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(TrustMapOuter.FOUND_LABEL, color = Color.White.copy(alpha = 0.75f), fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (ring in outer.rings) {
                    Text(
                        TrustMapOuter.chipText(ring), color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                        modifier = pill
                            .clickable(role = Role.Button) { open = ring }
                            .semantics { contentDescription = "${ring.hop} hops out, ${ring.count} people, found by your desktop Vault" }
                            .padding(horizontal = 12.dp, vertical = 6.dp),
                    )
                }
            }
        }
        outer.source == TrustMapOuter.Source.WAITING -> Text(
            TrustMapOuter.WAITING_LABEL, color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
            modifier = modifier.then(pill).padding(horizontal = 12.dp, vertical = 6.dp),
        )
        outer.source == TrustMapOuter.Source.INVITE && inviteHidden == false ->
            HavenInviteCard(accent, onNotNow = { HavenInviteSetting.setHidden(context, true) }, modifier = modifier)
    }
    open?.let { ring ->
        OuterRingSheet(ring, outer.bar, copy, profiles, onNeedProfiles,
            onPick = { open = null; onPick(it) }, onDismiss = { open = null })
    }
}
