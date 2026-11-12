package com.nostrvault.ui.components

import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.NewInWeb
import com.nostrvault.service.FeedService
import com.nostrvault.service.NostrService
import com.nostrvault.ui.theme.SecondaryText

/** Where each account's seen list is kept (iOS keeps it in UserDefaults under the same key). */
private const val NEWCOMERS_PREFS = "wot_newcomers"

/**
 * My Web's New in your web: people your follows have come to vouch for since
 * this device last looked, as faces (iOS `WotNewcomersView`, which the iPad's
 * Your space WoT panel shows too). A face is handed to [onOpen].
 */
@Composable
internal fun NewInWebSection(
    me: String,
    feedService: FeedService,
    nostrService: NostrService,
    profiles: Map<String, FeedProfile>,
    onOpen: (String) -> Unit,
) {
    val context = LocalContext.current
    val followed by feedService.followedPubkeys.collectAsState()
    val vouched by feedService.extendedNetworkPubkeys.collectAsState()
    val loading by feedService.isLoadingExtendedNetwork.collectAsState()
    var fresh by remember(me) { mutableStateOf(emptyList<String>()) }

    LaunchedEffect(me, vouched) {
        if (me.isEmpty() || vouched.isEmpty()) { fresh = emptyList(); return@LaunchedEffect }
        val prefs = context.applicationContext.getSharedPreferences(NEWCOMERS_PREFS, Context.MODE_PRIVATE)
        val key = NewInWeb.key(me)
        val next = NewInWeb.update(vouched, NewInWeb.fromJson(prefs.getString(key, null)),
            System.currentTimeMillis() / 1000)
        prefs.edit().putString(key, next.toJson()).apply()
        fresh = next.fresh.map { it.pubkey }
        nostrService.fetchMissingProfiles(fresh.take(NewInWeb.FACES))
    }
    // The web is worked out for the Discover feed; until that has run once, ask for it here.
    LaunchedEffect(Unit) {
        if (vouched.isEmpty() && followed.isNotEmpty() && !loading) feedService.countExtendedNetwork()
    }

    Column(
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Text(MyWebWords.NEWCOMERS_DETAIL, color = SecondaryText, fontSize = 12.sp)
        if (fresh.isEmpty()) {
            Text(MyWebWords.newcomersEmpty(vouched.isEmpty(), loading), color = SecondaryText, fontSize = 13.sp)
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                for (pk in fresh.take(NewInWeb.FACES)) {
                    val profile = profiles[pk]
                    val name = profile?.bestName ?: "them"
                    AvatarImage(
                        url = profile?.pictureURL, pubkey = pk, size = 40.dp, displayName = profile?.bestName,
                        modifier = Modifier
                            .clip(CircleShape)
                            .clickable(role = Role.Button) { onOpen(pk) }
                            .semantics { contentDescription = "Open $name in WoT" },
                    )
                }
                if (fresh.size > NewInWeb.FACES) {
                    Text("+${fresh.size - NewInWeb.FACES}", color = SecondaryText, fontSize = 12.sp,
                        fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}
