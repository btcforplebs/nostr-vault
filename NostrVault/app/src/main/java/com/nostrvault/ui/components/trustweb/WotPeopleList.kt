package com.nostrvault.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustPath
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.Surface1

/**
 * The WOT tab's list: with a card open, everyone linking you to them;
 * otherwise everyone in the lit layer, searchable. A row opens its card.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun WotPeopleList(
    card: String?,
    cardPath: TrustPath?,
    layer: TrustMap.Layer,
    listed: TrustMap.LayerPeople,
    myFollows: Set<String>,
    vouches: Map<String, Int>?,
    profiles: Map<String, FeedProfile>,
    accent: Color,
    name: (String) -> String,
    onSeen: (String) -> Unit,
    onOpen: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var query by remember { mutableStateOf("") }
    fun matches(pubkey: String): Boolean {
        val text = query.trim().lowercase()
        if (text.isEmpty() || pubkey.startsWith(text)) return true
        val profile = profiles[pubkey] ?: return false
        return listOf(profile.displayName, profile.name, profile.nip05).any { it?.lowercase()?.contains(text) == true }
    }
    @Composable
    fun row(pubkey: String) {
        val profile = profiles[pubkey]
        val linked = vouches?.get(pubkey) ?: 0
        LaunchedEffect(pubkey) { onSeen(pubkey) }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClickLabel = "Open their trust card") { onOpen(pubkey) }
                .padding(horizontal = 20.dp, vertical = 8.dp),
        ) {
            AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 32.dp, displayName = profile?.bestName)
            Column(Modifier.weight(1f)) {
                Text(name(pubkey), color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                val nip05 = profile?.nip05
                if (!nip05.isNullOrEmpty()) {
                    Text(nip05, color = SecondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            if (linked > 0) Text("$linked you follow", color = SecondaryText, fontSize = 12.sp)
        }
    }
    @Composable
    fun note(text: String) {
        Text(text, color = SecondaryText, fontSize = 15.sp, modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp))
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Surface1,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SecondaryText) },
    ) {
        val title = if (card != null) name(card) else if (layer == TrustMap.Layer.EVERYONE) "Your web" else layer.title
        Text(title, color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
        if (card == null) {
            SearchField(query = query, onQueryChange = { query = it }, onFocusChange = {}, onSearch = {},
                onClear = { query = "" }, accent = accent)
        }
        LazyColumn(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
            if (card != null) {
                if (card in myFollows) item { note("You follow ${name(card)}.") }
                when {
                    cardPath == null -> item { note("Finding who links you…") }
                    cardPath.all.isEmpty() -> item { note("None of the people you follow follow ${name(card)}.") }
                    else -> {
                        item { ListHeader("People you follow who follow ${name(card)} · ${cardPath.all.size}") }
                        items(cardPath.all, key = { it }) { row(it) }
                    }
                }
            } else {
                val following = listed.following.filter(::matches)
                val rest = listed.web.filter(::matches)
                if (following.isNotEmpty()) {
                    item { ListHeader("You follow · ${following.size}") }
                    items(following, key = { "f$it" }) { row(it) }
                }
                if (rest.isNotEmpty()) {
                    item { ListHeader("In your web · ${rest.size}") }
                    items(rest, key = { "w$it" }) { row(it) }
                }
                if (following.isEmpty() && rest.isEmpty()) {
                    item { note(if (query.isBlank()) "No one here yet." else "No one called \u201C${query.trim()}\u201D on your globe.") }
                }
            }
        }
    }
}

@Composable
internal fun ListHeader(text: String) {
    Text(
        text.uppercase(),
        color = SecondaryText,
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 0.5.sp,
        modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 16.dp, bottom = 4.dp),
    )
}
