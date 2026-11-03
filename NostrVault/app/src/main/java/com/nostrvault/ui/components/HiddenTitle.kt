package com.nostrvault.ui.components

import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics

/**
 * A screen title that is read out but not drawn (Logen 2026-11-03, c2bba1de): where header buttons ran into the
 * title, the text is dropped so the buttons have room, and screen readers still hear which screen this is.
 */
@Composable
fun HiddenTitle(text: String) {
    Box(Modifier.semantics { heading(); contentDescription = text })
}
