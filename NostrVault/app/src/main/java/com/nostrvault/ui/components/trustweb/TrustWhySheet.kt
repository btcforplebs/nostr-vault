package com.nostrvault.ui.components

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.TrustRankCopy
import com.nostrvault.data.model.TrustWhy
import com.nostrvault.data.model.TrustWhyText
import com.nostrvault.ui.screens.profile.ProfileHopEntryPoint
import com.nostrvault.ui.theme.*
import com.nostrvault.util.RelativeTime
import dagger.hilt.android.EntryPointAccessors

/**
 * "Why?" on a person's trust card: opens [TrustWhySheet]. Shown only when
 * your Haven's copy has a score for them; nothing otherwise.
 */
@Composable
internal fun TrustWhyButton(pubkey: String, accent: Color) {
    val context = LocalContext.current
    val services = remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, ProfileHopEntryPoint::class.java)
    }
    val me by services.configStore().activeAccountHexPubkey.collectAsState()
    var copy by remember(me) { mutableStateOf<TrustRankCopy?>(null) }
    LaunchedEffect(me) { copy = services.trustRankCopyStore().copyFor(me) }
    if (copy?.get(pubkey) == null || pubkey == me) return
    var open by remember(pubkey) { mutableStateOf(false) }
    TextButton(onClick = { open = true }, contentPadding = PaddingValues(horizontal = 8.dp)) {
        Text("Why?", color = accent, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
    if (open) TrustWhySheet(pubkey, me, copy, accent) { open = false }
}

/**
 * Score, ring and the people you follow who follow them, highest score
 * first. No mute rows (Logen's question 3 is open). iOS twin to come:
 * `Views/TrustWeb/TrustWhySheet.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TrustWhySheet(pubkey: String, me: String, copy: TrustRankCopy?, accent: Color, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val services = remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, ProfileHopEntryPoint::class.java)
    }
    val path = rememberLiveTrustPath(pubkey)
    val why = TrustWhy.of(pubkey, me, copy, path)
    val profiles by services.nostrService().profiles.collectAsState()
    LaunchedEffect(why?.followers) {
        why?.followers?.take(TrustWhy.SHOWN)?.map { it.pubkey }?.let { services.nostrService().fetchMissingProfiles(listOf(pubkey) + it) }
    }
    fun name(pk: String) = profiles[pk]?.bestName ?: "npub…${pk.takeLast(6)}"
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Surface1,
    ) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Why ${name(pubkey)}?", color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (why == null) {
                // The path can place them outside your web after all (an unfollow since the Haven ranked).
                Text(if (path == null) "Checking…" else "Your Haven's score for them is out of date.", color = SecondaryText, fontSize = 14.sp)
                return@Column
            }
            Text(TrustWhyText.headline(why), color = accent, fontSize = 28.sp, fontWeight = FontWeight.Bold)
            Text(TrustWhyText.place(why), color = PrimaryText, fontSize = 14.sp)
            Text(TrustWhyText.followersTitle(why), color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(top = 6.dp))
            for (f in why.followers.take(TrustWhy.SHOWN)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    val profile = profiles[f.pubkey]
                    AvatarImage(url = profile?.pictureURL, pubkey = f.pubkey, size = 28.dp, displayName = profile?.bestName)
                    Text(name(f.pubkey), color = PrimaryText, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f))
                    Text(f.score?.toString() ?: "–", color = SecondaryText, fontSize = 14.sp)
                }
            }
            TrustWhyText.more(why)?.let { Text(it, color = SecondaryText, fontSize = 13.sp) }
            Text(TrustWhyText.HOW, color = TertiaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 8.dp))
            val now = System.currentTimeMillis() / 1000
            Text("Ranked by your Haven ${RelativeTime.abbreviated(why.rankedAt, now)}", color = TertiaryText, fontSize = 12.sp)
        }
    }
}
