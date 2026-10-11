package com.nostrvault.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.Surface1

/** The globe as a list: for TalkBack, and anyone who'd rather read. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun PeopleList(
    frame: TrustFrame,
    me: String,
    author: String,
    profiles: Map<String, FeedProfile>,
    name: (String) -> String,
    onOpen: ((String) -> Unit)?,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Surface1,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SecondaryText) },
    ) {
        val chains = frame.chains.orEmpty()
        LazyColumn(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
            item {
                Text(name(frame.center), color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
            }
            if (frame.bridges.isNotEmpty()) {
                item {
                    ListHeader(
                        if (frame.center == me) "People you follow who follow ${name(author)}"
                        else "${name(frame.center)}'s follows who follow ${name(author)}",
                    )
                }
                items(frame.bridges, key = { it }) { pubkey ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .then(if (onOpen != null) Modifier.clickable(onClickLabel = "Open their profile") { onOpen(pubkey) } else Modifier)
                            .padding(horizontal = 20.dp, vertical = 8.dp),
                    ) {
                        val profile = profiles[pubkey]
                        AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 28.dp, displayName = profile?.bestName)
                        Text(name(pubkey), color = PrimaryText, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            if (chains.isNotEmpty()) {
                item { ListHeader("Further out") }
                items(chains.take(50)) { chain ->
                    Text(
                        "${name(chain.bridge)} → ${name(chain.via)} → ${name(author)}",
                        color = PrimaryText,
                        fontSize = 15.sp,
                        modifier = Modifier
                            .fillMaxWidth()
                            .then(if (onOpen != null) Modifier.clickable { onOpen(chain.via) } else Modifier)
                            .padding(horizontal = 20.dp, vertical = 10.dp),
                    )
                }
            }
            if (frame.bridges.isEmpty() && chains.isEmpty()) {
                item {
                    Text("No one on this globe follows ${name(author)} yet.", color = SecondaryText, fontSize = 15.sp,
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp))
                }
            }
        }
    }
}
