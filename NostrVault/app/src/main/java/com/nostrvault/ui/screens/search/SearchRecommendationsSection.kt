package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.SearchRecommendations
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.theme.*

/** People with a loaded profile; the rest show once theirs arrives. */
internal fun namedRecommendedPeople(
    people: List<SearchRecommendations.Person>,
    profiles: Map<String, FeedProfile>,
): List<Pair<SearchRecommendations.Person, FeedProfile>> =
    people.mapNotNull { person ->
        val profile = profiles[person.pubkey] ?: return@mapNotNull null
        if (profile.name.isNullOrBlank() && profile.displayName.isNullOrBlank()) null else person to profile
    }

/**
 * Search tab's "For you": people your follows follow, your topics and notes
 * that match them. Everything here was ranked on device from the relay's own
 * trust graph and feed ([SearchRecommendations]). iOS SearchRecommendationsSection.
 * Picked notes draw through [noteContent], the same card the results use.
 */
internal fun LazyListScope.searchRecommendationsSection(
    people: List<Pair<SearchRecommendations.Person, FeedProfile>>,
    topics: List<String>,
    notes: List<FeedNote>,
    colors: NostrVaultColorScheme,
    onProfile: (String) -> Unit,
    onTopic: (String) -> Unit,
    noteContent: @Composable (FeedNote) -> Unit,
) {
    if (people.isEmpty() && topics.isEmpty() && notes.isEmpty()) return

    item(key = "foryou-header") {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Icon(NostrVaultIcons.Sparkles, contentDescription = null, tint = colors.primary, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(6.dp))
            Text("For you", color = SecondaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Icon(NostrVaultIcons.Relay, contentDescription = null, tint = TertiaryText, modifier = Modifier.size(11.dp))
            Spacer(Modifier.width(4.dp))
            Text("Ranked by your relay", color = TertiaryText, fontSize = 10.sp)
        }
        Spacer(Modifier.height(14.dp))
    }

    if (people.isNotEmpty()) {
        item(key = "foryou-people") {
            ForYouSubheader("People you may know")
            LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                items(people, key = { it.first.pubkey }) { (person, profile) ->
                    RecommendedPersonCard(person, profile, onClick = { onProfile(person.pubkey) })
                }
            }
            Spacer(Modifier.height(14.dp))
        }
    }

    if (topics.isNotEmpty()) {
        item(key = "foryou-topics") {
            ForYouSubheader("Your topics")
            LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                items(topics, key = { it }) { tag ->
                    TrendingHashtagChip(tag = tag, onClick = { onTopic(tag) }, colors = colors)
                }
            }
            Spacer(Modifier.height(14.dp))
        }
    }

    if (notes.isNotEmpty()) {
        item(key = "foryou-notes-header") { ForYouSubheader("Picked from your topics") }
        items(notes, key = { "foryou-${it.id}" }) { note -> noteContent(note) }
    }

    item(key = "foryou-end") { Spacer(Modifier.height(24.dp)) }
}

@Composable
private fun ForYouSubheader(title: String) {
    Text(title, color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.Medium)
    Spacer(Modifier.height(8.dp))
}

@Composable
private fun RecommendedPersonCard(
    person: SearchRecommendations.Person,
    profile: FeedProfile,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(12.dp),
        color = SecondaryText.copy(alpha = 0.08f),
        modifier = Modifier
            .width(108.dp)
            .semantics(mergeDescendants = true) {
                contentDescription = "${profile.bestName}, followed by ${person.vouches} people you follow"
            },
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 10.dp),
        ) {
            AvatarImage(url = profile.pictureURL, pubkey = person.pubkey, size = 48.dp, displayName = profile.bestName)
            Spacer(Modifier.height(6.dp))
            Text(
                profile.bestName,
                color = PrimaryText,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
            )
            Text(
                "${person.vouches} of your follows",
                color = SecondaryText,
                fontSize = 10.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
