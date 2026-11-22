package com.nostrvault.ui.screens.profile

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.ProfileHopText
import com.nostrvault.data.model.TrustRankCopy
import com.nostrvault.service.NostrService
import com.nostrvault.service.TrustRankCopyStore
import com.nostrvault.ui.components.rememberLiveTrustPath
import com.nostrvault.ui.theme.SecondaryText
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent

@EntryPoint
@InstallIn(SingletonComponent::class)
interface ProfileHopEntryPoint {
    fun trustRankCopyStore(): TrustRankCopyStore
    fun nostrService(): NostrService
    fun configStore(): com.nostrvault.data.local.ConfigStore
}

/**
 * Under a profile's name: "2 hops · followed by Alice, Bob and 3 more", or
 * "4 hops" for someone only your Haven reaches ([ProfileHopText]). Nothing
 * for you, or for someone neither your web nor your Haven knows.
 */
@Composable
fun ProfileHopLine(pubkey: String, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val services = remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, ProfileHopEntryPoint::class.java)
    }
    val me by services.configStore().activeAccountHexPubkey.collectAsState()
    val path = rememberLiveTrustPath(pubkey.takeIf { it != me })
    var rank by remember(pubkey, me) { mutableStateOf<TrustRankCopy.Person?>(null) }
    LaunchedEffect(pubkey, me) { rank = services.trustRankCopyStore().copyFor(me)?.get(pubkey) }
    val profiles by services.nostrService().profiles.collectAsState()
    LaunchedEffect(path) {
        val named = path?.all?.ifEmpty { path.bridges }?.take(ProfileHopText.NAMED).orEmpty()
        if (named.isNotEmpty()) services.nostrService().fetchMissingProfiles(named)
    }
    val line = ProfileHopText.line(pubkey, me, path, rank) { profiles[it]?.bestName ?: "npub…${it.takeLast(6)}" }
        ?: return
    Text(text = line, color = SecondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = modifier)
}
