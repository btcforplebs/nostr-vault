package com.nostrvault.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.TrustMapOuter
import com.nostrvault.data.model.TrustRankCopy
import com.nostrvault.ui.screens.profile.ProfileHopEntryPoint
import com.nostrvault.ui.theme.*
import dagger.hilt.android.EntryPointAccessors
import kotlin.math.roundToInt

/**
 * One outer ring opened: its top people from the globe list, as your
 * desktop Vault scored them, best first, whatever their score. Tapping
 * someone opens "why?" with how they connect ([TrustWhySheet]).
 * iOS `Views/TrustWeb/OuterRingSheet.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun OuterRingSheet(
    ring: TrustMapOuter.Ring,
    copy: TrustRankCopy?,
    accent: Color,
    profiles: Map<String, FeedProfile>,
    onNeedProfiles: (List<String>) -> Unit,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val me by remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, ProfileHopEntryPoint::class.java).configStore().activeAccountHexPubkey
    }.collectAsState()
    var why by remember(ring.hop) { mutableStateOf<String?>(null) }
    LaunchedEffect(ring.hop) { onNeedProfiles(ring.top.take(60)) }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Surface1,
    ) {
        LazyColumn(Modifier.fillMaxWidth(), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 28.dp)) {
            item {
                Text("${ring.hop} hops away", color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                Text(
                    "${TrustMapOuter.FOUND_LABEL}. ${TrustMapOuter.countText(ring)}",
                    color = SecondaryText, fontSize = 13.sp, modifier = Modifier.padding(top = 4.dp, bottom = 10.dp),
                )
            }
            items(ring.top, key = { it }) { key ->
                val profile = profiles[key]
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.fillMaxWidth().clickable(role = Role.Button) { why = key }.padding(vertical = 8.dp),
                ) {
                    AvatarImage(url = profile?.pictureURL, pubkey = key, size = 36.dp, displayName = profile?.bestName)
                    Text(profile?.bestName ?: "npub…${key.takeLast(6)}", color = PrimaryText, fontSize = 15.sp,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    copy?.globeRow(key)?.let { Text("${it.score.roundToInt()}", color = SecondaryText, fontSize = 15.sp) }
                }
            }
        }
    }
    why?.let { key -> TrustWhySheet(key, me, copy, accent) { why = null } }
}
