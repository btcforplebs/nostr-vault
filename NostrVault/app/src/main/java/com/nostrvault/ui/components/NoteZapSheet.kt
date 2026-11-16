package com.nostrvault.ui.components

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable

/** The note a row's held bolt is zapping: its effective id and author (reposts resolve to the original). */
data class NoteZapTarget(val noteId: String, val pubkey: String)

/** The Wallet default for a one-tap zap, never under 1 sat (iOS FeedNoteRow quick zap). */
fun quickZapSats(defaultZapAmount: Int): Int = defaultZapAmount.coerceAtLeast(1)

/**
 * The custom amount sheet a held bolt opens on note rows outside the main
 * feed (profile, hashtag, search). A tap on the bolt zaps [quickZapSats]
 * without it, as in the feed. Shows nothing while [target] is null.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NoteZapSheet(
    target: NoteZapTarget?,
    defaultAmount: Int,
    onDismiss: () -> Unit,
    onZap: (NoteZapTarget, Int, String) -> Unit,
) {
    if (target == null) return
    CustomZapSheet(
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        defaultAmount = quickZapSats(defaultAmount),
        onDismiss = onDismiss,
        onZap = { amount, comment -> onZap(target, amount, comment) },
    )
}
