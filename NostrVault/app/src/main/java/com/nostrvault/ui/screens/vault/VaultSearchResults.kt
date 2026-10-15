package com.nostrvault.ui.screens.vault

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.VaultSearchLogic
import com.nostrvault.data.model.VaultSearchLogic.Section
import com.nostrvault.data.model.VaultSearchLogic.Status
import com.nostrvault.ui.components.VaultNoteCard
import com.nostrvault.ui.navigation.LocalOpenHashtag
import com.nostrvault.ui.screens.SearchProfileRow
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.ZapOrange

/** Rows per section under "All". */
private const val PREVIEW = 5
/** Rows in one section: the relay walk keeps every match; this keeps a common word from building thousands of rows. */
private const val SECTION_CAP = 200

private fun Section.icon(): ImageVector = when (this) {
    Section.PEOPLE -> NostrVaultIcons.People
    Section.NOTES -> NostrVaultIcons.Articles
    Section.ARTICLES -> NostrVaultIcons.Articles
    Section.MEDIA -> NostrVaultIcons.Media
    Section.HASHTAGS -> NostrVaultIcons.TagIcon
    Section.LINKS -> NostrVaultIcons.LinkIcon
}

/**
 * What the Vault's search found, in place of the Vault's list while the bar is
 * open (iOS `VaultSearchResults`): a row of section chips, then People, Notes,
 * Articles, Media, Hashtags and Links. "All" shows the first few of each; a chip
 * shows that section whole.
 */
@Composable
internal fun VaultSearchResults(
    status: Status,
    results: VaultSearchModel.Results,
    resultsQuery: String,
    profiles: Map<String, FeedProfile>,
    onProfile: (String) -> Unit,
    onNote: (FeedNote) -> Unit,
    contentPadding: PaddingValues,
) {
    var section by remember { mutableStateOf<Section?>(null) }
    LaunchedEffect(resultsQuery) { section = null }
    val visible = Section.entries.filter { results.count(it) > 0 }
    LazyColumn(contentPadding = contentPadding, modifier = Modifier.fillMaxWidth()) {
        when {
            status == Status.IDLE -> item {
                Message("Search your Vault", "Notes, people, hashtags, links, articles and media stored on this device's relay.")
            }
            status == Status.SEARCHING && results.isEmpty -> item {
                Row(
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().padding(top = 60.dp),
                ) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = SecondaryText)
                    Spacer(Modifier.width(10.dp))
                    Text("Searching your Vault…", color = SecondaryText, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                }
            }
            else -> {
                caveat(status)?.let { item { Caveat(it) } }
                if (status != Status.SEARCHING && results.isEmpty) {
                    item { Message("Nothing in your Vault matches", "“$resultsQuery”") }
                } else {
                    item {
                        LazyRow(
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            contentPadding = PaddingValues(horizontal = 16.dp),
                            modifier = Modifier.padding(vertical = 12.dp),
                        ) {
                            item { Chip("All", NostrVaultIcons.Search, null, section == null) { section = null } }
                            items(visible) { s -> Chip(s.title, s.icon(), results.count(s), section == s) { section = s } }
                        }
                    }
                    for (s in section?.let(::listOf) ?: visible) {
                        sectionItems(s, results, profiles, if (section == null) PREVIEW else SECTION_CAP, whole = section != null,
                            onSeeAll = { section = s }, onProfile = onProfile, onNote = onNote)
                    }
                }
            }
        }
    }
}

/** Why these results may not be everything, when they may not. */
private fun caveat(status: Status): String? = when (status) {
    Status.CUT_SHORT -> "The search ran out of time, so older items may be missing."
    Status.IN_MEMORY -> "Your Vault's relay is still starting, so this covers only what's loaded. Search again in a moment for everything."
    else -> null
}

private fun LazyListScope.sectionItems(
    s: Section,
    results: VaultSearchModel.Results,
    profiles: Map<String, FeedProfile>,
    limit: Int,
    whole: Boolean,
    onSeeAll: () -> Unit,
    onProfile: (String) -> Unit,
    onNote: (FeedNote) -> Unit,
) {
    val total = results.count(s)
    item(key = "head-$s") {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 8.dp),
        ) {
            Text(s.title, color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            if (total > limit && !whole) {
                Text("See all %,d".format(total), color = LocalNostrVaultColors.current.primary, fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold, modifier = Modifier.clickable(onClick = onSeeAll))
            }
        }
    }
    when (s) {
        Section.PEOPLE -> items(results.people.take(limit), key = { "p-${it.pubkey}" }) { profile ->
            SearchProfileRow(profile = profile, profiles = profiles, onClick = { onProfile(profile.pubkey) })
        }
        Section.NOTES, Section.ARTICLES, Section.MEDIA -> items(results.notes(s).take(limit), key = { "n-${it.id}" }) { note ->
            VaultNoteCard(
                note = note,
                profile = profiles[note.pubkey],
                profiles = profiles,
                onNoteClick = { onNote(note) },
                onArticleClick = { onNote(note) },
                onProfileClick = onProfile,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }
        Section.HASHTAGS -> items(results.hashtags.take(limit), key = { "h-$it" }) { tag -> HashtagRow(tag) }
        Section.LINKS -> items(results.links.take(limit), key = { "l-${it.url}" }) { link -> LinkRow(link) }
    }
    if (whole && total > limit) item(key = "cap-$s") {
        Text("Showing the newest %,d of %,d".format(limit, total), color = SecondaryText, fontSize = 12.sp,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
    }
}

@Composable
private fun Chip(title: String, icon: ImageVector, count: Int?, isOn: Boolean, onClick: () -> Unit) {
    val accent = LocalNostrVaultColors.current.primary
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = Modifier
            .height(32.dp)
            .background(if (isOn) accent else Color.White.copy(alpha = 0.12f), CircleShape)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp)
            .semantics { selected = isOn },
    ) {
        Icon(icon, contentDescription = null, tint = if (isOn) Color.White else PrimaryText, modifier = Modifier.size(14.dp))
        Text(title, color = if (isOn) Color.White else PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        if (count != null) {
            Text("%,d".format(count), color = if (isOn) Color.White.copy(alpha = 0.8f) else SecondaryText, fontSize = 12.sp)
        }
    }
}

/** A hashtag opens its own feed, as tapping a #tag in a note does. */
@Composable
private fun HashtagRow(tag: String) {
    val open = LocalOpenHashtag.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .padding(horizontal = 16.dp, vertical = 3.dp)
            .fillMaxWidth()
            .background(Color.White.copy(alpha = 0.06f), RoundedCornerShape(8.dp))
            .clickable(enabled = open != null) { open?.invoke(tag) }
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Text("#$tag", color = LocalNostrVaultColors.current.primary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.weight(1f))
        Icon(NostrVaultIcons.Navigate, contentDescription = null, tint = SecondaryText.copy(alpha = 0.5f),
            modifier = Modifier.size(14.dp))
    }
}

/** A URL that does not open stays an inert row rather than a dead link. */
@Composable
private fun LinkRow(link: VaultSearchLogic.Link) {
    val uri = LocalUriHandler.current
    Column(
        modifier = Modifier
            .padding(horizontal = 16.dp, vertical = 3.dp)
            .fillMaxWidth()
            .background(Color.White.copy(alpha = 0.06f), RoundedCornerShape(8.dp))
            .clickable { runCatching { uri.openUri(link.url) } }
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Text(link.title, color = LocalNostrVaultColors.current.primary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(link.url, color = SecondaryText, fontSize = 11.sp, fontFamily = FontFamily.Monospace, maxLines = 1,
            overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun Caveat(text: String) {
    Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.Top) {
        Icon(NostrVaultIcons.Alert, contentDescription = null, tint = ZapOrange, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(8.dp))
        Text(text, color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun Message(title: String, detail: String) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxWidth().padding(top = 60.dp, start = 32.dp, end = 32.dp),
    ) {
        Icon(NostrVaultIcons.Search, contentDescription = null, tint = LocalNostrVaultColors.current.primary,
            modifier = Modifier.size(40.dp))
        Text(title, color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.Bold)
        Text(detail, color = SecondaryText, fontSize = 13.sp, textAlign = TextAlign.Center)
    }
}
