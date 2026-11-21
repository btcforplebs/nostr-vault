package com.nostrvault.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import com.nostrvault.data.model.TrustGate

/**
 * Whose pictures [AvatarImage] may fetch. A screen that splits people with [TrustGate] provides it, so a stranger
 * outside your web (shown when you open "Outside your web") gets their constellation and their picture host learns
 * nothing (Logen 2026-11-21, web's `Avatar load={trusted(pk)}`). The default lets everyone through.
 */
val LocalAvatarGate = staticCompositionLocalOf<(String) -> Boolean> { { true } }

/** [content] with avatars gated by [TrustGate.allows]: [trusted] null (Everyone) lets everyone through. */
@Composable
fun AvatarTrustGate(trusted: Set<String>?, always: Set<String>, content: @Composable () -> Unit) {
    val gate = remember(trusted, always) { { pk: String -> TrustGate.allows(pk, trusted, always) } }
    CompositionLocalProvider(LocalAvatarGate provides gate, content = content)
}
