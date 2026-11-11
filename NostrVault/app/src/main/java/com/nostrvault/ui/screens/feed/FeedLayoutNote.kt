package com.nostrvault.ui.screens.feed

import com.nostrvault.data.model.FeedLayoutMode
import com.nostrvault.ui.components.FilterNote
import com.nostrvault.ui.theme.NostrVaultIcons

/**
 * What one tap on the feed's layout button did: the layout it switched to,
 * and Show replies when the switch moved it (null when it was already right).
 */
data class FeedLayoutSwitch(val layout: FeedLayoutMode, val repliesShown: Boolean?)

/**
 * The pill the layout button leaves under the toolbar, for the usual 2 s:
 * "Layout · Threaded, replies shown". The switch also sets replies, so the
 * note names both. Mirrors iOS `FeedToolbarState.note(changedFrom:)`.
 */
fun feedLayoutNote(switch: FeedLayoutSwitch): FilterNote {
    val name = when (switch.layout) {
        FeedLayoutMode.EXPANDED -> "Expanded"
        FeedLayoutMode.THREADED -> "Threaded"
    }
    val icon = when (switch.layout) {
        FeedLayoutMode.EXPANDED -> NostrVaultIcons.ExpandedView
        FeedLayoutMode.THREADED -> NostrVaultIcons.ThreadedView
    }
    val setting = switch.repliesShown?.let { "$name, replies ${if (it) "shown" else "hidden"}" } ?: name
    return FilterNote.setting(icon, "Layout", setting)
}
