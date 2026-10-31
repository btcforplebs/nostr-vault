package com.nostrvault.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.PostEngagement
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.delay

/**
 * Action button row. Mirrors the iOS feed note layout: capsule-background
 * icon buttons, left-aligned with fixed spacing, with a spring scale-up on
 * active states.
 * Order: Reply → Repost → Quote → Like → Zap, then Web of Trust where offered.
 *
 * Counts only where the screen fetched [engagement] (profiles), as on iOS:
 * each button carries its own number ("Reply 5", "Like 64+"), zero shows
 * none. Elsewhere the numbers belong to the thread view, which shows them as
 * its own row (ThreadNoteEngagementRow, the hero note's stats).
 *
 * **Five buttons, with Share and Broadcast in the ⋯ menu.** iOS put them in
 * the row and had no ⋯ menu, so a note there could not be reported, blocked
 * or copied; both apps now use this row plus the menu. Share sits next to
 * Copy link there, where it belongs. The one addition is Web of Trust (iOS
 * d584a294), a sixth uncounted 40dp cell: 240dp of the 312dp row.
 *
 * **Every child is unweighted, deliberately.** An equal `weight(1f)` hands each
 * cell the same width whether it needs 32dp or 58dp, and inside a counted cell
 * the count is the last child measured — so the shortfall lands on it and it is
 * clipped to a sliver of one glyph, silently, with a green build. Unweighted,
 * a cell measures at what it needs, the slack stays at the end of the row, and
 * a genuine overflow drops a whole button where you can see it.
 *
 * `spacedBy` rather than `SpaceBetween` for the same reason it is not weighted:
 * nothing in this app caps the content width (no `widthIn`, no
 * `WindowSizeClass`, no `sw600dp` resources, no `screenOrientation` lock), so a
 * landscape phone is one ~800dp column and an elastic spread would put ~140dp
 * of air between buttons. The child count is also runtime-variable — Quote is
 * gated on its handler, Like disappears under Zaps Only — so the gaps would
 * differ between two notes in the same scroll.
 *
 * Every button is gated on its own handler. Quote already was; the rest
 * rendered at full opacity, took the tap and ran the pulse into
 * `handler?.invoke(...)`. On a screen that passes no handlers — search
 * results — that is a row of buttons animating a confirmation for an event
 * nobody signed. One rule now: no handler, no affordance.
 */
@Composable
internal fun EngagementBar(
    noteId: String,
    isLiked: Boolean,
    isZapped: Boolean,
    isReposted: Boolean = false,
    onReply: ((String) -> Unit)?,
    onRepost: ((String) -> Unit)?,
    onQuote: ((String) -> Unit)?,
    onLike: ((String) -> Unit)?,
    onZap: ((String) -> Unit)?,
    onLongPressLike: ((String) -> Unit)? = null,
    onLongPressZap: ((String) -> Unit)? = null,
    zapDimmed: Boolean = false,
    engagement: PostEngagement? = null,
    /** Web of Trust for the author; null on your own notes and where it isn't offered. */
    onTrustWeb: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    fun label(value: Long) = engagement?.let { postEngagementLabel(value, it.isAtLeast(value)) }
    fun spoken(value: Long, noun: String) =
        engagement?.let { postEngagementDescription(value, noun, it.isAtLeast(value)) }
    // No spacing here: each button carries its own 4dp a side inside its tap
    // target, so the drawn gap is still 8dp and the pitch is still 40dp, with
    // no dead strip between two targets. See [EngagementButton].
    // Five counted buttons do not always fit a 360dp phone ("12+", "2.1k+"…),
    // so a row with profile counts scrolls rather than clipping Zap.
    val counted = engagement != null
    Row(
        horizontalArrangement = Arrangement.spacedBy(0.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .then(if (counted) Modifier.horizontalScroll(rememberScrollState()) else Modifier),
    ) {
        // Reply
        if (onReply != null) {
            EngagementButton(
                icon = NostrVaultIcons.ReplyAction,
                isActive = false,
                activeColor = SecondaryText,
                contentDescription = "Reply",
                onClick = { onReply.invoke(noteId) },
                count = engagement?.let { label(it.replies.toLong()) },
                countDescription = engagement?.let { spoken(it.replies.toLong(), "replies") },
            )
        }

        // Repost
        if (onRepost != null) {
            EngagementButton(
                icon = NostrVaultIcons.Repost,
                isActive = isReposted,
                activeColor = RepostGreen,
                contentDescription = if (isReposted) "Reposted" else "Repost",
                onClick = { onRepost.invoke(noteId) },
                count = engagement?.let { label(it.reposts.toLong()) },
                countDescription = engagement?.let { spoken(it.reposts.toLong(), "reposts") },
            )
        }

        // Quote
        if (onQuote != null) {
            EngagementButton(
                icon = NostrVaultIcons.Quote,
                isActive = false,
                activeColor = SecondaryText,
                contentDescription = "Quote",
                onClick = { onQuote.invoke(noteId) },
                count = engagement?.let { label(it.quotes.toLong()) },
                countDescription = engagement?.let { spoken(it.quotes.toLong(), "quotes") },
            )
        }

        // Like: tap reacts or takes it back, hold opens the tapback bar
        // (its "+" is the emoji picker). Hidden entirely in Zaps Only mode.
        if (onLike != null && !LocalZapsOnlyMode.current) {
            ReactionButton(
                noteId = noteId,
                isLiked = isLiked,
                onTap = { onLike.invoke(noteId) },
                onMore = onLongPressLike?.let { more -> { more(noteId) } },
                count = engagement?.let { label(it.likes.toLong()) },
                countDescription = engagement?.let { spoken(it.likes.toLong(), "likes") },
            )
        }

        // Zap, unless ⚡️ was taken out of Appearance → Post buttons.
        val zapAction = onZap?.takeIf { LocalShowZapButton.current }
        if (zapAction != null) Box(Modifier.zapFlightTarget(noteId)) {
            EngagementButton(
                icon = if (isZapped) NostrVaultIcons.Zap else NostrVaultIcons.ZapOutline,
                isActive = isZapped,
                activeColor = ZapOrange,
                contentDescription = if (isZapped) "Zapped" else "Zap",
                onClick = { zapAction.invoke(noteId) },
                onLongClick = onLongPressZap?.let { longPress -> { longPress(noteId) } },
                dimmed = zapDimmed && !isZapped,
                count = engagement?.let { label(it.zapSats) },
                countDescription = engagement?.let { spoken(it.zapSats, "sats zapped") },
            )
        } else if (engagement != null && engagement.zapSats > 0) {
            // No wallet to zap from, but the sats others sent still show
            // (iOS FeedNoteRow: a filled bolt and the total, not a button).
            ReadOnlyZapTotal(
                count = label(engagement.zapSats) ?: "",
                description = spoken(engagement.zapSats, "sats zapped") ?: "",
            )
        }

        // Web of Trust: how you reach the author. Opens a map, publishes
        // nothing, so it never shows as active.
        if (onTrustWeb != null) {
            EngagementButton(
                icon = NostrVaultIcons.TabWoT,
                isActive = false,
                activeColor = SecondaryText,
                contentDescription = "Web of Trust",
                onClick = onTrustWeb,
            )
        }

        // Slack stays here, at the end, rather than being spread between the
        // buttons — see the arrangement note above. A scrolling row has no
        // slack to hold.
        if (!counted) Spacer(Modifier.weight(1f))
    }
}

/**
 * The zap total on a note you cannot zap (no wallet): [EngagementButton]'s
 * capsule and spacing, with nothing to tap. iOS draws it with the bolt at 85%.
 */
@Composable
private fun ReadOnlyZapTotal(count: String, description: String) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .height(48.dp)
            .padding(horizontal = 4.dp)
            .clearAndSetSemantics { contentDescription = description },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .height(32.dp)
                .widthIn(min = 32.dp)
                .clip(CircleShape)
                .background(SecondaryText.copy(alpha = 0.10f))
                .padding(horizontal = 9.dp),
        ) {
            Icon(
                imageVector = NostrVaultIcons.Zap,
                contentDescription = null,
                tint = ZapOrange.copy(alpha = 0.85f),
                modifier = Modifier.size(16.dp),
            )
            Spacer(Modifier.width(4.dp))
            Text(
                text = count,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                color = SecondaryText,
                maxLines = 1,
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun EngagementButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    isActive: Boolean,
    activeColor: androidx.compose.ui.graphics.Color,
    contentDescription: String?,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
    count: String? = null,
    /** [count] as TalkBack reads it ("at least 64 likes"). */
    countDescription: String? = null,
    /** Drawn faint and without the tap pulse: the tap explains why it can't act. */
    dimmed: Boolean = false,
) {
    val tint = if (isActive) activeColor else if (dimmed) SecondaryText.copy(alpha = 0.35f) else SecondaryText
    val background = if (isActive) {
        activeColor.copy(alpha = 0.18f)
    } else {
        SecondaryText.copy(alpha = 0.10f)
    }
    // The pulse fires on the *tap*, not on `isActive`.
    //
    // Bound to state, it replayed on every reaction that arrived from backfill
    // or from another client — icons bouncing unprompted down a scrolling feed.
    // iOS routes this through `Motion.firePulse` for exactly that reason: the
    // caller owns the tap, not the resulting state. The tint and background
    // below still track `isActive`, because those carry the *meaning* and should
    // update however the state arrived.
    //
    // Numbers come from the shared token now: 1.12 rather than the 1.2 this
    // had, and damping 0.62 rather than 0.45 — the old inline comment was
    // citing an iOS spec that has since been retired.
    var pulsing by remember { mutableStateOf(false) }
    LaunchedEffect(pulsing) {
        if (pulsing) {
            delay(Motion.PULSE_HOLD_MS)
            pulsing = false
        }
    }
    val scale by animateFloatAsState(
        targetValue = if (pulsing) Motion.PULSE_SCALE else 1f,
        animationSpec = Motion.pop(),
        label = "engagementScale",
    )

    // No pulse at all under Reduce Motion, matching `Motion.firePulse`'s early
    // return — the icon's fill and colour already carry the confirmation.
    //
    // Only the tap pulses. A long press opens a picker sheet rather than
    // publishing anything, so there is no signed event for the bounce to be
    // confirming.
    val tapAndPulse = {
        if (!Motion.isReduced && !dimmed) pulsing = true
        onClick()
    }

    // The tap target is the outer node, not the capsule. The capsule is 32dp and
    // stays 32dp — this is the shape the row was measured around (see
    // [EngagementBar]) — but Material's minimum touch target is 48dp and a
    // 32dp one on a row of seven, with Zap and Repost one tap from a real
    // consequence, is where mis-taps get expensive.
    //
    // Vertically that is free: 48dp of height costs the card 16dp and nothing
    // else, so the target is a full 48dp tall.
    //
    // Horizontally it is not free, and 48dp wide does not fit. The row has
    // 312dp on a 360dp phone; three counted capsules at their widest label
    // ("999k", "9.9M" — `formatCount` never exceeds four glyphs) plus two
    // 32dp circles plus the gaps is 282dp, and taking each circle to 48dp
    // costs 32dp more than the 30dp left. So the target takes the *gap*
    // instead: the 8dp between buttons moves inside the clickable node, 4dp a
    // side, which leaves the drawn spacing at 8dp and the pitch at 40dp
    // exactly as before while removing the dead strip between two targets.
    // 40x48 contiguous, rather than 32x32 with 8dp of nothing around it.
    //
    // `indication` has to be stated because the clickable is now outside the
    // clip: bounded, it would ripple the whole 40x48 rect instead of the
    // capsule. An unbounded 20dp radius draws the same 40dp state layer
    // Material's own `IconButton` uses.
    val interactionSource = remember { MutableInteractionSource() }
    val indication = ripple(bounded = false, radius = 20.dp)
    val clickModifier = if (onLongClick != null) {
        Modifier.combinedClickable(
            interactionSource = interactionSource,
            indication = indication,
            onClick = tapAndPulse,
            onLongClick = onLongClick,
        )
    } else {
        Modifier.clickable(
            interactionSource = interactionSource,
            indication = indication,
            onClick = tapAndPulse,
        )
    }

    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .scale(scale)
            .height(48.dp)
            .then(clickModifier)
            .padding(horizontal = 4.dp),
    ) {
    // With a count the button becomes a capsule wide enough for the number; with
    // none it stays the 32dp circle it has always been. Height is fixed at 32dp
    // either way so a row of mixed buttons does not step up and down as counts
    // arrive from backfill.
    Row(
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .height(32.dp)
            .then(if (count == null) Modifier.width(32.dp) else Modifier.widthIn(min = 32.dp))
            .clip(CircleShape)
            .background(background)
            .then(if (count == null) Modifier else Modifier.padding(horizontal = 9.dp)),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            tint = tint,
            modifier = Modifier.size(16.dp),
        )
        if (count != null) {
            Spacer(Modifier.width(4.dp))
            Text(
                text = count,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                color = tint,
                maxLines = 1,
                modifier = if (countDescription == null) Modifier
                else Modifier.semantics { this.contentDescription = countDescription },
            )
        }
    }
    }
}
