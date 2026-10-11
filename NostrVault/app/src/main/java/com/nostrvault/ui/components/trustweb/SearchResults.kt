package com.nostrvault.ui.components

import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.TrustMap
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.Surface2
import kotlinx.coroutines.flow.first
import kotlin.math.max

/**
 * The search's results over the globe: people you follow first, then your
 * wider web, then anyone the relays know. While relays are being asked, a
 * last row says so; their answers re-rank this list as they land.
 */
@Composable
internal fun SearchResults(
    query: String,
    hits: List<TrustMap.PersonHit>,
    searching: Boolean,
    profiles: Map<String, FeedProfile>,
    name: (String) -> String,
    accent: Color,
    onPick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .padding(horizontal = 12.dp, vertical = 4.dp)
            .widthIn(max = 560.dp)
            .fillMaxWidth()
            .shadow(12.dp, RoundedCornerShape(14.dp))
            .clip(RoundedCornerShape(14.dp))
            .background(Surface2.copy(alpha = 0.96f))
            .verticalScroll(rememberScrollState())
            .padding(vertical = 4.dp),
    ) {
        for (hit in hits) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClickLabel = "Move them to the middle of the globe") { onPick(hit.pubkey) }
                    .padding(horizontal = 14.dp, vertical = 8.dp)
                    .semantics(mergeDescendants = true) { },
            ) {
                val profile = profiles[hit.pubkey]
                AvatarImage(url = profile?.pictureURL, pubkey = hit.pubkey, size = 32.dp, displayName = profile?.bestName)
                Text(name(hit.pubkey), color = PrimaryText, fontSize = 15.sp, maxLines = 1,
                    overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                when (hit.tier) {
                    TrustMap.Tier.FOLLOW -> Text("You follow", color = accent, fontSize = 12.sp, maxLines = 1)
                    TrustMap.Tier.WEB -> Text("In your web", color = SecondaryText, fontSize = 12.sp, maxLines = 1)
                    TrustMap.Tier.OTHER -> {}
                }
            }
        }
        if (searching) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
            ) {
                Box(Modifier.size(32.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = accent, strokeWidth = 1.5.dp, modifier = Modifier.size(16.dp))
                }
                Text("Searching relays…", color = SecondaryText, fontSize = 14.sp)
            }
        } else if (hits.isEmpty()) {
            Text(
                "No one called \u201c$query\u201d yet",
                color = SecondaryText,
                fontSize = 14.sp,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            )
        }
    }
}
