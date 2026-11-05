package com.nostrvault.ui.screens

import com.nostrvault.util.RelativeTime
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.VaultActivity
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.appendTextWithEmoji
import com.nostrvault.ui.components.customEmojiInlineContent
import com.nostrvault.ui.components.reactionEmojiSummary
import com.nostrvault.ui.theme.InfoBlue
import com.nostrvault.ui.theme.LikeRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.RepostGreen
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.WarningYellow
import com.nostrvault.ui.theme.ZapOrange
import kotlinx.coroutines.flow.drop
import java.text.NumberFormat

private const val AVATAR_LIMIT = 6

/** Account pictures shown on a line before "+N". */
internal const val ACCOUNT_STACK_LIMIT = 3

/** "+2" past [ACCOUNT_STACK_LIMIT], or null. */
internal fun accountStackMore(count: Int): String? = (count - ACCOUNT_STACK_LIMIT).takeIf { it > 0 }?.let { "+$it" }

@Composable
private fun AccountStack(accounts: List<String>, profiles: Map<String, FeedProfile>, modifier: Modifier = Modifier) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = modifier) {
        accounts.take(ACCOUNT_STACK_LIMIT).forEachIndexed { i, hex ->
            AvatarImage(
                url = profiles[hex]?.pictureURL,
                pubkey = hex,
                size = 18.dp,
                displayName = profiles[hex]?.bestName,
                modifier = Modifier.offset(x = (-8 * i).dp).border(2.dp, SecondaryGroupedBg, CircleShape),
            )
        }
        accountStackMore(accounts.size)?.let {
            Text(it, color = SecondaryText, fontSize = 10.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.offset(x = (-8 * ACCOUNT_STACK_LIMIT + 2).dp))
        }
    }
}

/** One notification-style line: what happened, who did it, what it was about. */
@Composable
internal fun VaultActivityRow(
    line: VaultActivity,
    isUnread: Boolean,
    profiles: Map<String, FeedProfile>,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    /**
     * The accounts the line is for, when the list holds more than one account's lines: one, or several when one
     * event tagged several of them (VaultAccountChips.merge).
     */
    accounts: List<String> = emptyList(),
) {
    val colors = LocalNostrVaultColors.current
    val (icon, tint) = activityStyle(line.kind, colors.primary)
    val name: (String) -> String = { pubkey -> profiles[pubkey]?.bestName ?: ("npub…" + pubkey.takeLast(6)) }
    val who = VaultActivity.who(line.actors, name)
    val verb = activityVerb(line)
    val preview = remember(line.preview, profiles) { readablePreview(line.preview, name) }
    val shape = RoundedCornerShape(12.dp)
    Row(
        verticalAlignment = Alignment.Top,
        modifier = modifier
            .fillMaxWidth()
            .background(colors.primary.copy(alpha = if (isUnread) 0.10f else 0.03f), shape)
            .border(0.8.dp, colors.primary.copy(alpha = 0.18f), shape)
            .clickable(onClick = onClick)
            .padding(14.dp)
            .semantics(mergeDescendants = true) {
                contentDescription = (if (accounts.isEmpty()) "" else "For ${accounts.joinToString(", ") { name(it) }}. ") + "$who $verb. $preview"
                if (isUnread) stateDescription = "New"
            },
    ) {
        Box {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.size(34.dp).background(tint.copy(alpha = 0.15f), CircleShape),
            ) {
                Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(17.dp))
            }
            if (accounts.isNotEmpty()) {
                // Whose notification this is: those accounts' pictures stacked on the line's icon (up to 3, then
                // +N). The names are read out, not printed on every line. iOS: accountMark (#1772).
                AccountStack(accounts, profiles, Modifier.align(Alignment.BottomEnd).offset(x = 5.dp, y = 5.dp))
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Row(Modifier.weight(1f)) {
                    line.actors.take(AVATAR_LIMIT).forEachIndexed { index, pubkey ->
                        val profile = profiles[pubkey]
                        AvatarImage(
                            url = profile?.pictureURL,
                            pubkey = pubkey,
                            size = 30.dp,
                            displayName = profile?.bestName,
                            // A ring keeps overlapping faces apart (iOS).
                            modifier = Modifier.offset(x = (-8 * index).dp).border(2.dp, SecondaryGroupedBg, CircleShape),
                        )
                    }
                    if (line.actors.size > AVATAR_LIMIT) {
                        Text(
                            "+${line.actors.size - AVATAR_LIMIT}",
                            color = SecondaryText, fontSize = 11.sp, fontWeight = FontWeight.Bold,
                            modifier = Modifier
                                .align(Alignment.CenterVertically)
                                .offset(x = (-8 * AVATAR_LIMIT + 6).dp),
                        )
                    }
                }
                Text(RelativeTime.abbreviated(line.createdAt, System.currentTimeMillis() / 1000), color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                if (isUnread) {
                    Spacer(Modifier.width(8.dp))
                    Box(Modifier.size(8.dp).background(colors.primary, CircleShape))
                }
            }
            Spacer(Modifier.height(8.dp))
            // A custom emoji reaction draws its image (NIP-30).
            val emojiContent = remember(line.customEmojis) { customEmojiInlineContent(line.customEmojis) }
            Text(
                buildAnnotatedString {
                    withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(who) }
                    append(" ")
                    appendTextWithEmoji(verb, line.customEmojis)
                },
                color = PrimaryText,
                fontSize = 15.sp,
                inlineContent = emojiContent,
            )
            if (preview.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                if (line.aboutYourPost) {
                    // Your own post, when they only reacted to it: quieter and
                    // behind a rule, so the two never read alike.
                    Row(Modifier.height(IntrinsicSize.Min)) {
                        Box(
                            Modifier
                                .width(3.dp)
                                .fillMaxHeight()
                                .background(tint.copy(alpha = 0.5f), CircleShape),
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(preview, color = SecondaryText, fontSize = 14.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                } else {
                    Text(preview, color = PrimaryText, fontSize = 15.sp, maxLines = 4, overflow = TextOverflow.Ellipsis)
                }
            }
            if (line.images.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                VaultActivityThumbnails(line.images)
            }
        }
    }
}

private fun activityStyle(kind: VaultActivity.Kind, primary: Color): Pair<ImageVector, Color> = when (kind) {
    VaultActivity.Kind.REPLY -> NostrVaultIcons.Reply to primary
    VaultActivity.Kind.MENTION -> NostrVaultIcons.At to primary
    VaultActivity.Kind.QUOTE -> NostrVaultIcons.Quote to InfoBlue
    VaultActivity.Kind.REACTION -> NostrVaultIcons.HeartFilled to LikeRed
    VaultActivity.Kind.REPOST -> NostrVaultIcons.Repost to RepostGreen
    VaultActivity.Kind.ZAP -> NostrVaultIcons.Zap to ZapOrange
    VaultActivity.Kind.ARTICLE -> NostrVaultIcons.Articles to primary
    VaultActivity.Kind.HIGHLIGHT -> NostrVaultIcons.Highlights to WarningYellow
    VaultActivity.Kind.FOLLOW -> NostrVaultIcons.PersonAdd to primary
}

/** The iPhone's words for each line. */
private fun activityVerb(line: VaultActivity): String = when (line.kind) {
    VaultActivity.Kind.REPLY -> "replied to you"
    VaultActivity.Kind.MENTION -> "mentioned you"
    VaultActivity.Kind.QUOTE -> "quoted your note"
    VaultActivity.Kind.REACTION -> {
        val emojis = reactionEmojiSummary(line.emojis, limit = 3, customShortcodes = line.customEmojis.keys)
        if (emojis == "❤️") "liked your note" else "reacted $emojis to your note"
    }
    VaultActivity.Kind.REPOST -> "reposted your note"
    VaultActivity.Kind.ZAP -> {
        val sats = NumberFormat.getIntegerInstance().format(line.sats)
        if (line.openId == null) "zapped you $sats sats" else "zapped your note $sats sats"
    }
    VaultActivity.Kind.ARTICLE -> "tagged you in an article"
    VaultActivity.Kind.HIGHLIGHT -> "highlighted you"
    VaultActivity.Kind.FOLLOW -> "followed you"
}

/**
 * The preview with `nostr:` links made readable: people become @names,
 * links to posts drop out (a one-line preview can't show them).
 */
private fun readablePreview(preview: String, name: (String) -> String): String {
    if (!preview.contains("nostr:")) return preview
    return preview.split(" ").mapNotNull { word ->
        if (!word.startsWith("nostr:")) return@mapNotNull word
        val id = word.removePrefix("nostr:").trim { !it.isLetterOrDigit() }
        val pubkey = when {
            id.startsWith("npub1") -> runCatching { HavenBridge.decodeNpub(id) }.getOrNull()
            id.startsWith("nprofile1") -> runCatching { HavenBridge.decodeNprofilePubkey(id) }.getOrNull()
            else -> null
        }
        pubkey?.let { "@" + name(it) }
    }.joinToString(" ")
}
