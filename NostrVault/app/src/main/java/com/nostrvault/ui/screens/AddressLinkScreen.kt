package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.QuoteRef
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.FeedService
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.TertiaryText

/** Where a resolved addressable event opens: the reader for an article, the thread otherwise. */
internal fun addressDestination(kind: Int, eventId: String): String =
    if (kind == 30023) Screen.ArticleReader.createRoute(eventId) else Screen.NoteDetail.createRoute(eventId)

/**
 * A `nostr:naddr1…` link from another app. Asks the user's own relays for the
 * event the address names (never the relay hint in the link), then replaces
 * itself with the article or post. Port of iOS NoteDetailLoader's naddr path
 * (`NoteDetailView.swift` fetchNote).
 */
@Composable
fun AddressLinkScreen(
    naddr: String,
    feedService: FeedService,
    onResolved: (route: String) -> Unit,
    onBack: () -> Unit,
) {
    // The router already checked this; check again, since a route can be reached other ways.
    val coordinate = remember(naddr) {
        HavenBridge.decodeNaddr(naddr)?.takeIf { QuoteRef.isLinkableKind(it.kind) }
    }
    var error by remember(naddr) { mutableStateOf(if (coordinate == null) "Could not read this link" else null) }

    LaunchedEffect(coordinate) {
        val c = coordinate ?: return@LaunchedEffect
        val note = feedService.resolveAddress(c)
        if (note == null) error = "Could not find this post on your relays" else onResolved(addressDestination(note.kind, note.id))
    }

    Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxSize().padding(32.dp)) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            val message = error
            if (message == null) {
                CircularProgressIndicator()
                Spacer(Modifier.height(16.dp))
                Text("Fetching…", color = SecondaryText)
            } else {
                Icon(NostrVaultIcons.Alert, contentDescription = null, tint = TertiaryText, modifier = Modifier.size(40.dp))
                Spacer(Modifier.height(12.dp))
                Text(message, color = SecondaryText, fontSize = 15.sp, textAlign = TextAlign.Center)
                Spacer(Modifier.height(16.dp))
                TextButton(onClick = onBack) { Text("Back") }
            }
        }
    }
}
