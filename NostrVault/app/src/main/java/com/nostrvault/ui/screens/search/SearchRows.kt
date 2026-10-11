package com.nostrvault.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.SearchSourceState
import com.nostrvault.data.model.SearchSourceStatus
import com.nostrvault.ui.theme.*

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun SearchSourcesRow(
    sources: List<SearchSourceState>,
    colors: NostrVaultColorScheme,
) {
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        sources.forEach { source -> SearchSourceChip(source, colors) }
    }
}

@Composable
private fun SearchSourceChip(
    source: SearchSourceState,
    colors: NostrVaultColorScheme,
) {
    val status = source.status
    val (text, tint) = when (status) {
        is SearchSourceStatus.Searching ->
            (if (source.count > 0) "${source.count} so far" else "searching") to SecondaryText
        is SearchSourceStatus.Found ->
            "${status.count} found" to (if (status.count > 0) colors.primary else SecondaryText)
        is SearchSourceStatus.NoAnswer -> "no answer: ${status.reason}" to TertiaryText
    }
    val label = source.detail?.let { "${source.label} (${it})" } ?: source.label
    Surface(
        shape = RoundedCornerShape(14.dp),
        color = SeparatorColor.copy(alpha = 0.12f),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
        ) {
            if (status is SearchSourceStatus.Searching) {
                CircularProgressIndicator(
                    color = colors.primary,
                    strokeWidth = 1.5.dp,
                    modifier = Modifier.size(10.dp),
                )
                Spacer(Modifier.width(6.dp))
            }
            Text(
                text = label,
                color = PrimaryText.copy(alpha = 0.8f),
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text = text,
                color = tint,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.widthIn(max = 200.dp),
            )
        }
    }
}

@Composable
internal fun SearchProfileRow(
    profile: FeedProfile,
    profiles: Map<String, FeedProfile> = emptyMap(),
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        AvatarImage(
            url = profile.pictureURL,
            pubkey = profile.pubkey,
            size = 44.dp,
            displayName = profile.bestName,
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = profile.bestName,
                color = PrimaryText,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            profile.nip05?.let {
                Text(text = it, color = SecondaryText, fontSize = 13.sp)
            }
            profile.about?.takeIf { it.isNotBlank() }?.let { about ->
                Text(
                    text = remember(about, profiles) {
                        NostrMentions.toPlainText(about, profiles).replace("\n", " ")
                    },
                    color = TertiaryText,
                    fontSize = 13.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
internal fun SearchSectionHeader(title: String) {
    Text(
        text = title,
        color = SecondaryText,
        fontSize = 14.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

@Composable
internal fun SearchHashtagRow(
    tag: String,
    onClick: () -> Unit,
    colors: NostrVaultColorScheme,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(8.dp),
        color = SeparatorColor.copy(alpha = 0.08f),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
        ) {
            Text(
                text = "#$tag",
                color = colors.primary,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            Icon(
                imageVector = NostrVaultIcons.Navigate,
                contentDescription = null,
                tint = SecondaryText.copy(alpha = 0.5f),
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

/** Opens the link in the browser. */
@Composable
internal fun SearchLinkRow(
    link: SearchLink,
    colors: NostrVaultColorScheme,
) {
    val uriHandler = LocalUriHandler.current
    Surface(
        onClick = { runCatching { uriHandler.openUri(link.url) } },
        shape = RoundedCornerShape(8.dp),
        color = SeparatorColor.copy(alpha = 0.08f),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp),
    ) {
        Column(modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
            Text(
                text = link.title,
                color = colors.primary,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = link.url,
                color = SecondaryText,
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
internal fun RecentSearchChip(query: String, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(14.dp),
        color = SeparatorColor.copy(alpha = 0.12f),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
        ) {
            Icon(
                imageVector = NostrVaultIcons.History,
                contentDescription = null,
                tint = SecondaryText,
                modifier = Modifier.size(12.dp),
            )
            Spacer(Modifier.width(4.dp))
            Text(
                text = query,
                color = PrimaryText.copy(alpha = 0.8f),
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
            )
        }
    }
}

@Composable
internal fun TrendingHashtagChip(
    tag: String,
    onClick: () -> Unit,
    colors: NostrVaultColorScheme,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(14.dp),
        color = colors.primary.copy(alpha = 0.12f),
    ) {
        Text(
            text = "#$tag",
            color = colors.primary,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
        )
    }
}

@Composable
internal fun SuggestedProfileRow(
    profile: FeedProfile,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 6.dp),
    ) {
        AvatarImage(
            url = profile.pictureURL,
            pubkey = profile.pubkey,
            size = 34.dp,
            displayName = profile.bestName,
        )
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = profile.bestName,
                color = PrimaryText,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            profile.nip05?.takeIf { it.isNotBlank() }?.let {
                Text(text = it, color = SecondaryText, fontSize = 11.sp, maxLines = 1)
            }
        }
        Icon(
            imageVector = NostrVaultIcons.Navigate,
            contentDescription = null,
            tint = SecondaryText.copy(alpha = 0.5f),
            modifier = Modifier.size(14.dp),
        )
    }
}
