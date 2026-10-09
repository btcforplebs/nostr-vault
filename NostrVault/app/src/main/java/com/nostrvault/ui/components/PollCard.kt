package com.nostrvault.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckBoxOutlineBlank
import androidx.compose.material.icons.filled.RadioButtonChecked
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.NIP88Poll
import com.nostrvault.service.NostrService
import com.nostrvault.service.PollStore
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.ErrorRed
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject
import kotlin.math.roundToInt

/** Hands a poll card the shared [PollStore] and who is voting. */
@HiltViewModel
class PollViewModel @Inject constructor(
    val store: PollStore,
    private val nostrService: NostrService,
) : ViewModel() {
    val me: String get() = nostrService.activeHexPubkey
    val profiles: StateFlow<Map<String, FeedProfile>> = nostrService.profiles
}

/**
 * A NIP-88 poll inside a note row: the question, its options and the count.
 * Tapping an option votes (single choice) or picks it (multiple choice, sent
 * with Vote). Results show once you have voted or the poll has closed.
 * Focused, as the note detail's own card, each option also shows who picked
 * it. iOS PollCardView.
 */
@Composable
fun PollCard(
    poll: NIP88Poll.Poll,
    isFocused: Boolean = false,
    /**
     * Picture and link URLs the note draws below as media and cards — left in
     * the question they showed as bare links (Logen, 2026-10-07).
     */
    hiddenURLs: Set<String> = emptySet(),
    viewModel: PollViewModel = hiltViewModel(),
    modifier: Modifier = Modifier,
) {
    val model = remember(poll.id) { viewModel.store.model(poll) }
    val state by model.state.collectAsState()
    val accent = LocalNostrVaultColors.current.primary

    val me = viewModel.me
    val myPicks = state.tally.picksByVoter[me].orEmpty()
    val isClosed = poll.isClosed()
    val showsResults = isClosed || myPicks.isNotEmpty()
    val canVote = !isClosed && me.isNotEmpty()
    // Multiple choice: what is ticked but not sent yet. Starts as, and
    // follows, the vote already counted.
    var picked by remember(poll.id) { mutableStateOf(emptySet<String>()) }
    LaunchedEffect(myPicks) { picked = myPicks.toSet() }
    LaunchedEffect(poll.id) { model.load() }

    Column(
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = modifier
            .fillMaxWidth()
            .padding(top = 4.dp),
    ) {
        val question = remember(poll.question, hiddenURLs) {
            hiddenURLs.fold(poll.question) { text, url -> text.replace(url, "") }.trim()
        }
        if (question.isNotEmpty()) {
            Text(
                text = question,
                color = PrimaryText,
                fontSize = if (isFocused) 19.sp else 17.sp,
                fontWeight = FontWeight.SemiBold,
                lineHeight = if (isFocused) 25.sp else 23.sp,
            )
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            for (option in poll.options) {
                val mine = option.id in myPicks
                val selected = if (poll.type == NIP88Poll.PollType.MULTIPLE) option.id in picked else mine
                PollOptionRow(
                    option = option,
                    type = poll.type,
                    selected = selected,
                    share = state.tally.share(option.id),
                    count = state.tally.count(option.id),
                    showsResults = showsResults,
                    enabled = canVote && !state.isSending,
                    accent = accent,
                    onClick = {
                        when (poll.type) {
                            NIP88Poll.PollType.SINGLE -> if (myPicks != listOf(option.id)) model.vote(listOf(option.id))
                            NIP88Poll.PollType.MULTIPLE -> picked = if (option.id in picked) picked - option.id else picked + option.id
                        }
                    },
                )
                if (isFocused && showsResults) {
                    PollOptionVoters(
                        pubkeys = state.tally.votersByOption[option.id].orEmpty().sorted(),
                        viewModel = viewModel,
                    )
                }
            }
        }

        if (poll.type == NIP88Poll.PollType.MULTIPLE && canVote && picked.isNotEmpty() && myPicks.toSet() != picked) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 36.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(accent)
                    .clickable(enabled = !state.isSending, role = Role.Button) {
                        model.vote(poll.options.map { it.id }.filter { it in picked })
                    },
            ) {
                Text(
                    text = if (myPicks.isEmpty()) "Vote" else "Change vote",
                    color = Color.White,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }

        PollFooter(
            voters = state.tally.voters.size,
            poll = poll,
            isClosed = isClosed,
            isBusy = state.isSending || state.isLoading,
        )

        state.sendError?.let {
            Text(text = it, color = ErrorRed, fontSize = 12.sp)
        }
    }
}

@Composable
private fun PollOptionRow(
    option: NIP88Poll.Option,
    type: NIP88Poll.PollType,
    selected: Boolean,
    share: Double,
    count: Int,
    showsResults: Boolean,
    enabled: Boolean,
    accent: Color,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(10.dp)
    val bar by animateFloatAsState(
        targetValue = if (showsResults) share.toFloat().coerceIn(0f, 1f) else 0f,
        animationSpec = tween(250),
        label = "pollShare",
    )
    val barColor = accent.copy(alpha = if (selected) 0.28f else 0.14f)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(SecondaryText.copy(alpha = 0.1f))
            .drawBehind {
                // The option's share, filled from the leading edge.
                if (bar > 0f) drawRect(barColor, size = Size(size.width * bar, size.height))
            }
            .then(if (selected) Modifier.border(BorderStroke(1.dp, accent.copy(alpha = 0.7f)), shape) else Modifier)
            .clickable(enabled = enabled, role = if (type == NIP88Poll.PollType.SINGLE) Role.RadioButton else Role.Checkbox, onClick = onClick)
            .semantics {
                contentDescription = option.label
                this.selected = selected
                if (showsResults) stateDescription = if (count == 1) "1 vote" else "$count votes"
            },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
        ) {
            Icon(
                imageVector = when (type) {
                    NIP88Poll.PollType.SINGLE -> if (selected) Icons.Filled.RadioButtonChecked else Icons.Filled.RadioButtonUnchecked
                    NIP88Poll.PollType.MULTIPLE -> if (selected) Icons.Filled.CheckBox else Icons.Filled.CheckBoxOutlineBlank
                },
                contentDescription = null,
                tint = if (selected) accent else SecondaryText,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(10.dp))
            Text(
                text = option.label,
                color = PrimaryText,
                fontSize = 15.sp,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                modifier = Modifier.weight(1f),
            )
            if (showsResults) {
                Spacer(Modifier.width(8.dp))
                Text(
                    text = "${(share * 100).roundToInt()}%",
                    color = if (selected) accent else SecondaryText,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

@Composable
private fun PollFooter(voters: Int, poll: NIP88Poll.Poll, isClosed: Boolean, isBusy: Boolean) {
    val text = buildString {
        append(if (voters == 1) "1 vote" else "$voters votes")
        if (poll.type == NIP88Poll.PollType.MULTIPLE) append(" · Pick any")
        poll.endsAt?.let { endsAt ->
            append(" · ")
            append(if (isClosed) "Final results" else pollEndsText(endsAt, System.currentTimeMillis() / 1000))
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            imageVector = NostrVaultIcons.BarChart,
            contentDescription = null,
            tint = SecondaryText,
            modifier = Modifier.size(12.dp),
        )
        Spacer(Modifier.width(6.dp))
        Text(
            text = text,
            color = SecondaryText,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        if (isBusy) {
            Spacer(Modifier.width(6.dp))
            CircularProgressIndicator(
                color = SecondaryText,
                strokeWidth = 1.5.dp,
                modifier = Modifier.size(10.dp),
            )
        }
    }
}

/**
 * The people behind one option, in the note detail. Kept apart from the card
 * so only the detail's card watches profiles.
 */
@Composable
private fun PollOptionVoters(pubkeys: List<String>, viewModel: PollViewModel) {
    if (pubkeys.isEmpty()) return
    val profiles by viewModel.profiles.collectAsState()
    val shown = pubkeys.take(SHOWN_VOTER_AVATARS)
    // Overlapping by 6dp each, the way OverlappingAvatars stacks them.
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.padding(start = 12.dp),
    ) {
        shown.forEachIndexed { index, pubkey ->
            AvatarImage(
                url = profiles[pubkey]?.pictureURL,
                pubkey = pubkey,
                size = 22.dp,
                displayName = profiles[pubkey]?.bestName,
                modifier = Modifier
                    .offset(x = (-6).dp * index)
                    .border(1.dp, Color.Black.copy(alpha = 0.6f), CircleShape),
            )
        }
        if (pubkeys.size > shown.size) {
            Text(
                text = "+${pubkeys.size - shown.size}",
                color = SecondaryText,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.offset(x = (-6).dp * shown.size + 10.dp),
            )
        }
    }
}

private const val SHOWN_VOTER_AVATARS = 12

/** "Ends in 5m" / "Ends in 3h" / "Ends in 2d", for a poll still open at [nowSecs]. */
internal fun pollEndsText(endsAtSecs: Long, nowSecs: Long): String {
    val left = (endsAtSecs - nowSecs).coerceAtLeast(0)
    return when {
        left < 60 -> "Ends in under a minute"
        left < 3_600 -> "Ends in ${left / 60}m"
        left < 86_400 -> "Ends in ${left / 3_600}h"
        else -> "Ends in ${left / 86_400}d"
    }
}
