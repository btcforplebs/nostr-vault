package com.nostrvault.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

@Composable
internal fun TrustWebActions(
    frame: TrustFrame?,
    author: String,
    centerKey: String,
    me: String,
    deeperFailed: Set<String>,
    lookingDeeper: Set<String>,
    loadingMore: Set<String>,
    failed: Set<String>,
    accent: Color,
    name: (String) -> String,
    onProfileClick: ((String) -> Unit)?,
    lookDeeper: () -> Unit,
    showEveryone: () -> Unit,
    openProfile: (String) -> Unit,
) {
    if (frame != null && frame.listFound) {
        when {
            frame.center in deeperFailed -> FooterButton("Try again", accent, filled = false, onClick = lookDeeper)
            frame.center in lookingDeeper ->
                FooterButton("Looking further out…", accent, filled = false, loading = true, onClick = {})
            canLookDeeper(frame, author) -> FooterButton("Look deeper", accent, filled = false, onClick = lookDeeper)
            canLoadMore(frame) -> {
                val loading = frame.center in loadingMore
                FooterButton(
                    title = when {
                        loading -> "Finding more… ${frame.bridges.size} so far"
                        frame.center in failed -> "Couldn't reach the relays. Try again"
                        else -> "Show everyone who follows ${name(author)}"
                    },
                    accent = accent,
                    filled = false,
                    loading = loading,
                    onClick = showEveryone,
                )
            }
        }
    }
    if (centerKey != me && onProfileClick != null) {
        FooterButton("View ${name(centerKey)}'s profile", accent, filled = true) { openProfile(centerKey) }
    }
}
