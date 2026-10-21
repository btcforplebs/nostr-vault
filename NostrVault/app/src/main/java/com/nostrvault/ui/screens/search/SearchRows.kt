package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DesktopMac
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.NostrMentions
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.SearchSourceKind
import com.nostrvault.data.model.SearchSourceState
import com.nostrvault.data.model.SearchSourceStatus
import com.nostrvault.ui.theme.*

/** One chip per Global search source on one scrolling line: searching / N found / no answer (iOS globalSourceStrip). */
@Composable
internal fun SearchSourcesRow(sources: List<SearchSourceState>) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        sources.forEach { source -> SearchSourceChip(source) }
    }
}

@Composable
private fun SearchSourceChip(source: SearchSourceState) {
    val status = source.status
    // iOS havenOnline has no Android token; SuccessGreen is the nearest green.
    // ZapOrange is the same value as iOS system orange in dark mode.
    val (text, tint) = when (status) {
        is SearchSourceStatus.Searching ->
            (if (source.count > 0) "${source.count} so far" else "searching") to SecondaryText
        is SearchSourceStatus.Found ->
            "${status.count} found" to (if (status.count > 0) SuccessGreen else SecondaryText)
        is SearchSourceStatus.NoAnswer -> "no answer: ${status.reason}" to ZapOrange
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(searchSecondary(0.1f))
            .padding(horizontal = 10.dp, vertical = 5.dp),
    ) {
        if (status is SearchSourceStatus.Searching) {
            CircularProgressIndicator(color = SecondaryText, strokeWidth = 1.5.dp, modifier = Modifier.size(10.dp))
        } else {
            Icon(source.kind.icon, contentDescription = null, tint = tint, modifier = Modifier.size(11.dp))
        }
        Text(
            text = source.label,
            color = PrimaryText.copy(alpha = 0.85f),
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
        source.detail?.let { Text(text = it, color = SecondaryText, fontSize = 10.sp, maxLines = 1) }
        Text(text = text, color = tint, fontSize = 11.sp, maxLines = 1)
    }
}

/** iphone / desktopcomputer / antenna, as iOS marks each source. */
private val SearchSourceKind.icon: ImageVector
    get() = when (this) {
        SearchSourceKind.PHONE -> Icons.Filled.Smartphone
        SearchSourceKind.MAC -> Icons.Filled.DesktopMac
        SearchSourceKind.RELAY -> NostrVaultIcons.Relay
    }

/**
 * A person in the results: boxed card row like iOS userRow (40 avatar, 13
 * semibold name, chevron). The nip05/bio subtitle is Android's own; iOS shows
 * a hex prefix there (pending product call).
 */
@Composable
internal fun SearchProfileRow(
    profile: FeedProfile,
    profiles: Map<String, FeedProfile> = emptyMap(),
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(searchSecondary(0.05f))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        AvatarImage(
            url = profile.pictureURL,
            pubkey = profile.pubkey,
            size = 40.dp,
            displayName = profile.bestName,
        )
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                text = profile.bestName,
                color = PrimaryText,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            profile.nip05?.let {
                Text(text = it, color = SecondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
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
        Icon(
            imageVector = NostrVaultIcons.Navigate,
            contentDescription = null,
            tint = searchSecondary(0.5f),
            modifier = Modifier.size(14.dp),
        )
    }
}

/** 13 semibold, 12 above the rows; [first] sits 16 below the field, the rest 24 below the section above. */
@Composable
internal fun SearchSectionHeader(title: String, first: Boolean) {
    Text(
        text = title,
        color = SecondaryText,
        fontSize = 13.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = if (first) 16.dp else 24.dp, bottom = 12.dp),
    )
}

/** Rows in a section are 8 apart and inset 16, as iOS stacks them. */
internal fun Modifier.searchSectionRow(last: Boolean): Modifier =
    padding(start = 16.dp, end = 16.dp, bottom = if (last) 0.dp else 8.dp)

@Composable
internal fun SearchHashtagRow(
    tag: String,
    onClick: () -> Unit,
    colors: NostrVaultColorScheme,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(8.dp),
        color = searchSecondary(0.05f),
        modifier = modifier.fillMaxWidth(),
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
    modifier: Modifier = Modifier,
) {
    val uriHandler = LocalUriHandler.current
    Surface(
        onClick = { runCatching { uriHandler.openUri(link.url) } },
        shape = RoundedCornerShape(8.dp),
        color = searchSecondary(0.05f),
        modifier = modifier.fillMaxWidth(),
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
