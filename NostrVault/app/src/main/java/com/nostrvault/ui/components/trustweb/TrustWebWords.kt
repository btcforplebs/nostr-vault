package com.nostrvault.ui.components

import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.only
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import com.nostrvault.data.model.TrustPath
import com.nostrvault.ui.theme.PrimaryText

/**
 * "47", or "at least 5" while relays may hold more: the count is only the
 * signed lists actually checked, never a number a relay states.
 */
internal fun countText(frame: TrustFrame): String =
    if (frame.exhausted) "${frame.bridges.size}" else "at least ${frame.bridges.size}"

internal fun canLoadMore(frame: TrustFrame): Boolean =
    !frame.exhausted && frame.bridges.isNotEmpty() &&
        (frame.path.hasMore || frame.bridges.size > TrustPath.SHOWN_BRIDGES)

/**
 * No one at the core's follows follows the author: offer the two-step search
 * further out, which costs a few MB, so only on a tap.
 */
internal fun canLookDeeper(frame: TrustFrame, author: String): Boolean =
    frame.bridges.isEmpty() && frame.chains == null && frame.center != author && author !in frame.ringSet

internal fun explainer(
    frame: TrustFrame?,
    me: String,
    author: String,
    centerKey: String,
    name: (String) -> String,
    myFollows: Set<String>,
    lookingDeeper: Boolean,
    deeperFailed: Boolean,
    accent: Color,
    /** The WOT tab's follow list came back empty: say so rather than "tap anyone". */
    noFollows: Boolean = false,
): AnnotatedString = buildAnnotatedString {
    if (frame == null) {
        append("Loading who ${name(centerKey)} follows…")
        return@buildAnnotatedString
    }
    val them = name(author)
    val center = if (frame.center == me) null else name(frame.center)
    fun bold(text: String, color: Color = accent) =
        withStyle(SpanStyle(color = color, fontWeight = FontWeight.Bold)) { append(text) }
    val direct = author in frame.ringSet
    val chains = frame.chains
    when {
        !frame.listFound -> append("No relay checked had ${name(frame.center)}'s follow list, so their globe can't be drawn.")
        lookingDeeper -> append("Looking two steps further out. This downloads a few MB of follow lists.")
        deeperFailed -> append("Couldn't reach the relays to look further out.")
        noFollows -> append("No follows found yet. Follow people and they'll appear here.")
        // The WOT tab, before anyone is picked.
        frame.center == author && author == me ->
            append("Everyone you follow, and your web around them. Tap anyone to see how they reach you.")
        frame.center == author -> append("Everyone $them follows. Tap a face to see their path.")
        frame.bridges.isNotEmpty() -> when {
            center != null -> {
                append("$center reaches $them through ")
                bold(countText(frame))
                append(" of their follows. ")
                bold("${frame.ring.count { it in myFollows }}", PrimaryText)
                append(" of $center's follows are people you follow too (bright stars).")
            }
            direct -> {
                append("You follow $them, and so do ")
                bold(countText(frame))
                append(" people you follow.")
            }
            else -> {
                append("Followed by ")
                bold(countText(frame))
                append(" people you follow.")
            }
        }
        direct -> append("${center ?: "You"} ${if (center == null) "follow" else "follows"} $them directly.")
        chains != null && chains.isNotEmpty() -> {
            bold("${chains.map { it.via }.toSet().size}")
            append(" people who follow $them are followed by ${center?.let { "people $it follows" } ?: "people you follow"}.")
        }
        chains != null -> append("No longer route turned up in the follow lists checked.")
        else -> append(
            when (frame.path.reach) {
                TrustPath.Reach.WEB -> "In your Web of Trust through people further out. Look deeper to see who."
                TrustPath.Reach.OUTSIDE -> "Not in your web. No one you follow follows them, in the lists checked."
                TrustPath.Reach.UNKNOWN ->
                    if (center != null) "None of $center's follows that were checked follow $them."
                    else "Your trust graph hasn't loaded yet."
                else -> "Tap a face to follow their path."
            },
        )
    }
}

/** The globe's words for TalkBack, which reads the picture as one element. */
internal fun summary(frame: TrustFrame?, me: String, author: String, centerKey: String, name: (String) -> String): String {
    if (frame == null) return "Loading who ${name(centerKey)} follows."
    if (frame.center == me && author == me) {
        return "You, the ${frame.ring.size} people you follow, and your web around them."
    }
    val them = name(author)
    val who = if (frame.center == me) "you follow" else "${name(frame.center)} follows"
    if (frame.bridges.isEmpty()) {
        return if (author in frame.ringSet) "${name(frame.center)} follows $them directly."
        else "No one $who was seen following $them."
    }
    val named = frame.bridges.take(2).joinToString(", ") { name(it) }
    return "$them is followed by ${countText(frame)} people $who, including $named."
}
