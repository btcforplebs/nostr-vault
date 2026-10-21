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
