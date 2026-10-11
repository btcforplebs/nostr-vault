package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

@Composable
internal fun TrustWebSidePanel(
    author: String,
    profiles: Map<String, FeedProfile>,
    centerKey: String,
    me: String,
    name: (String) -> String,
    explainer: AnnotatedString,
    frame: TrustFrame?,
    tapped: (String) -> Unit,
    legend: @Composable () -> Unit,
    actions: @Composable () -> Unit,
) {
    Column(
        verticalArrangement = Arrangement.spacedBy(16.dp),
        modifier = Modifier
            .width(360.dp)
            .fillMaxHeight()
            .background(Color.Black.copy(alpha = 0.35f))
            .padding(24.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            val profile = profiles[author]
            AvatarImage(url = profile?.pictureURL, pubkey = author, size = 48.dp, displayName = profile?.bestName)
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(name(author), color = PrimaryText, fontSize = 19.sp, fontWeight = FontWeight.SemiBold,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(if (centerKey == me) "How you're connected" else "How ${name(centerKey)} is connected",
                    color = SecondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        Text(explainer, color = PrimaryText.copy(alpha = 0.85f), fontSize = 15.sp)
        legend()
        actions()
        Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.12f)))
        if (frame != null && frame.bridges.isNotEmpty()) {
            Text("FOLLOWED BY", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                letterSpacing = 1.2.sp)
            LazyColumn(Modifier.weight(1f)) {
                items(frame.bridges, key = { it }) { pubkey ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(onClickLabel = "Move them to the middle of the globe") { tapped(pubkey) }
                            .padding(vertical = 5.dp)
                            .semantics(mergeDescendants = true) { },
                    ) {
                        val profile = profiles[pubkey]
                        AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 32.dp, displayName = profile?.bestName)
                        Text(name(pubkey), color = PrimaryText, fontSize = 15.sp, maxLines = 1,
                            overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                        Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = SecondaryText,
                            modifier = Modifier.size(16.dp))
                    }
                }
            }
        } else {
            Spacer(Modifier.weight(1f))
        }
        Text(
            "Drag to spin · pinch to zoom · tap a face to follow their path · double-tap to reset",
            color = SecondaryText, fontSize = 11.sp, modifier = Modifier.clearAndSetSemantics { },
        )
    }
}
