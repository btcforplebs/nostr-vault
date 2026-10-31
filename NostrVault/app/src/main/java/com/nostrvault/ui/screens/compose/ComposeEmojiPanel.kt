package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.nostrvault.data.local.EmojiCatalog
import com.nostrvault.data.local.ReactionPick
import com.nostrvault.ui.components.EmojiPickerGrid
import com.nostrvault.ui.components.EmojiPickerSections
import com.nostrvault.ui.components.rememberEmojiCatalog

/**
 * The composer's emoji panel, docked under the toolbar where the keyboard
 * sits (Amethyst's `EmojiPanel`). It stays open so several emoji can go in,
 * and gives way when the keyboard comes back. Picks go in at the caret:
 * Unicode as is, custom emoji as `:shortcode:` (tagged on post).
 */
@Composable
internal fun ComposeEmojiPanel(
    viewModel: ComposeNoteViewModel,
    onPick: (ReactionPick) -> Unit,
    onSearchFocusChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette by viewModel.emojiPalette.state.collectAsState()
    val library by viewModel.emojiList.library.collectAsState()
    LaunchedEffect(Unit) { viewModel.emojiList.refresh() }
    val catalog = rememberEmojiCatalog()
    val sections = remember(catalog, palette, library) {
        EmojiPickerSections.build(catalog ?: EmojiCatalog(emptyList()), palette, library, custom = true)
    }
    EmojiPickerGrid(
        sections = sections,
        names = catalog?.names.orEmpty(),
        onPick = onPick,
        gridHeight = 240.dp,
        onSearchFocusChange = onSearchFocusChange,
        modifier = modifier.fillMaxWidth().padding(top = 8.dp),
    )
}
