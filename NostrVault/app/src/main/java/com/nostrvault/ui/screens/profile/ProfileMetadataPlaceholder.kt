package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.components.SkeletonTextLine
import com.nostrvault.ui.theme.SecondaryText
import kotlinx.coroutines.delay

/**
 * While a profile's kind 0 has not arrived, the header holds the space the
 * NIP-05 line and a short bio usually take, so the tabs and notes are not
 * pushed down when it lands. iOS ProfileContent awaitingMetadata.
 */
object ProfileMetadataWait {
    /** How long the header waits before giving up on the placeholders. */
    const val CAP_MILLIS = 5_000L

    /** No kind 0 for this person yet, and the wait is not over. */
    fun awaiting(profile: FeedProfile?, waitOver: Boolean): Boolean {
        if (waitOver) return false
        val p = profile ?: return true
        return p.name == null && p.displayName == null && p.about == null &&
            p.pictureURL == null && p.nip05 == null && p.lud16 == null
    }
}

/** True once [ProfileMetadataWait.CAP_MILLIS] has passed since [pubkey]'s profile opened. */
@Composable
internal fun rememberMetadataWaitOver(pubkey: String): Boolean {
    var over by remember(pubkey) { mutableStateOf(false) }
    LaunchedEffect(pubkey) {
        delay(ProfileMetadataWait.CAP_MILLIS)
        over = true
    }
    return over
}

/** A NIP-05 line's worth of placeholder, under the name. */
@Composable
internal fun Nip05Placeholder() {
    SkeletonTextLine(
        fontSize = 12.sp,
        widthFraction = 0.45f,
        color = SecondaryText.copy(alpha = 0.15f),
        modifier = Modifier.clearAndSetSemantics { },
    )
}

/** Two lines of bio placeholder, sized like the bio it stands in for. */
@Composable
internal fun BioPlaceholder() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 12.dp)
            .clearAndSetSemantics { },
    ) {
        for (fraction in listOf(0.92f, 0.6f)) {
            SkeletonTextLine(
                fontSize = 13.sp,
                lineHeight = 18.sp,
                widthFraction = fraction,
                color = SecondaryText.copy(alpha = 0.15f),
            )
        }
    }
}
