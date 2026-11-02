package com.nostrvault.ui.screens.settings.listbackup

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.components.AvatarImage

/** A person's name as the app knows it, else a short npub while their profile loads; never hex. */
internal fun personName(hex: String, known: Map<String, FeedProfile>): String =
    known[hex]?.let { it.displayName?.takeIf(String::isNotBlank) ?: it.name?.takeIf(String::isNotBlank) }
        ?: runCatching { HavenBridge.hexToNpub(hex) }.getOrNull()?.let { "${it.take(10)}…${it.takeLast(4)}" }
        ?: "Someone"

/** One entry of a list on the restore and merge screens: a person as picture + name, anything else as [text]. */
@Composable
internal fun ListEntryLabel(
    person: String?,
    text: String,
    known: Map<String, FeedProfile>,
    color: androidx.compose.ui.graphics.Color,
    fontSize: TextUnit,
    modifier: Modifier = Modifier,
) {
    if (person == null) {
        Text(text, color = color, fontSize = fontSize, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = modifier)
        return
    }
    val name = personName(person, known)
    Row(verticalAlignment = Alignment.CenterVertically, modifier = modifier) {
        AvatarImage(url = known[person]?.pictureURL, pubkey = person, size = 24.dp, displayName = name)
        Spacer(Modifier.width(8.dp))
        Text(name, color = color, fontSize = fontSize, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}
