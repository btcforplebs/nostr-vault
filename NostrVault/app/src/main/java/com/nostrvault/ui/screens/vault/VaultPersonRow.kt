package com.nostrvault.ui.screens.vault

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/**
 * The name a person row leads with: their name, or for someone with no
 * profile yet (a pasted npub) the whole npub, so its start and end can be
 * checked against what was pasted. iOS `ProfileResultRow.title`.
 */
internal fun vaultPersonTitle(profile: FeedProfile, npub: (String) -> String?): String {
    val named = listOf(profile.displayName, profile.name).any { !it.isNullOrEmpty() }
    if (!named) npub(profile.pubkey)?.let { return it }
    return profile.bestName
}

/**
 * A person in the Vault's search: avatar, the name (a bare npub cut in the
 * middle), NIP-05 in mono, two lines of about, and a chevron. The Vault's
 * own row, so the Search tab's row stays as it is. iOS `ProfileResultRow`.
 */
@Composable
internal fun VaultPersonRow(
    profile: FeedProfile,
    profiles: Map<String, FeedProfile>,
    onClick: () -> Unit,
) {
    val title = remember(profile) { vaultPersonTitle(profile) { runCatching { HavenBridge.encodeNpub(it) }.getOrNull() } }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        AvatarImage(url = profile.pictureURL, pubkey = profile.pubkey, size = 44.dp, displayName = profile.bestName)
        Spacer(Modifier.width(14.dp))
        Column(verticalArrangement = Arrangement.spacedBy(3.dp), modifier = Modifier.weight(1f)) {
            MiddleTruncatedText(title, TextStyle(color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold))
            profile.nip05?.takeIf { it.isNotEmpty() }?.let {
                Text(it, color = SecondaryText, fontSize = 12.sp, fontFamily = FontFamily.Monospace,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            profile.about?.takeIf { it.isNotEmpty() }?.let { about ->
                Text(
                    remember(about, profiles) { NostrMentions.toPlainText(about, profiles) },
                    color = SecondaryText.copy(alpha = SecondaryText.alpha * 0.8f),
                    fontSize = 13.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Spacer(Modifier.width(14.dp))
        Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = SecondaryText.copy(alpha = SecondaryText.alpha * 0.5f),
            modifier = Modifier.size(14.dp))
    }
}

/** One line cut in the middle ("npub1abc…xyz") when it does not fit, as iOS `.truncationMode(.middle)`. */
@Composable
private fun MiddleTruncatedText(text: String, style: TextStyle) {
    val measurer = rememberTextMeasurer()
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val width = constraints.maxWidth
        val shown = remember(text, style, width) {
            fun fits(s: String) = measurer.measure(s, style, maxLines = 1, softWrap = false,
                constraints = Constraints(maxWidth = Constraints.Infinity)).size.width <= width
            if (width == Constraints.Infinity || fits(text)) text
            else {
                // The most characters kept, split evenly around the "…".
                var lo = 0
                var hi = text.length
                while (lo < hi) {
                    val mid = (lo + hi + 1) / 2
                    if (fits(middleCut(text, mid))) lo = mid else hi = mid - 1
                }
                middleCut(text, lo)
            }
        }
        Text(shown, style = style, maxLines = 1, softWrap = false)
    }
}

/** [text] with only [keep] characters left, half from each end around "…". */
internal fun middleCut(text: String, keep: Int): String {
    if (keep >= text.length) return text
    val head = (keep + 1) / 2
    return text.take(head) + "…" + text.takeLast(keep - head)
}
