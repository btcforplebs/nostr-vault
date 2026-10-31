package com.nostrvault.ui.components

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.unit.dp
import com.nostrvault.data.local.EmojiCatalog
import com.nostrvault.data.local.EmojiPalette
import com.nostrvault.data.local.ReactionPick
import com.nostrvault.service.CustomEmoji
import com.nostrvault.service.EmojiListRepository
import com.nostrvault.ui.theme.*

/**
 * Emoji reaction picker bottom sheet, Amethyst-style: the quick bar, a
 * search pill, a section strip and one grid ([EmojiPickerGrid]).
 *
 * With [onSelectCustom] it is the reaction picker: the quick bar (which
 * can be edited), Recent, the account's own custom emoji and each pack it
 * added come first. Without it (choosing the default reaction) it offers
 * Unicode only. The composer has its own panel, `ComposeEmojiPanel`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EmojiPickerSheet(
    sheetState: SheetState,
    onDismiss: () -> Unit,
    onSelectEmoji: (String) -> Unit,
    onSelectCustom: ((CustomEmoji) -> Unit)? = null,
) {
    val haptic = LocalHapticFeedback.current
    val actions = LocalReactionActions.current
    val reacting = onSelectCustom != null && actions != null
    // The quick-bar slot being changed, while editing it.
    var editing by remember { mutableStateOf(false) }
    var editSlot by remember { mutableStateOf<ReactionPick?>(null) }

    val palette by rememberPalette(actions)
    val library by rememberLibrary(actions)
    LaunchedEffect(reacting) { if (reacting) actions?.refreshLibrary?.invoke() }
    val catalog = rememberEmojiCatalog()
    val sections = remember(catalog, palette, library, reacting) {
        EmojiPickerSections.build(catalog ?: EmojiCatalog(emptyList()), palette, library, custom = reacting)
    }

    fun choose(pick: ReactionPick) {
        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
        val slot = editSlot
        if (editing && slot != null && actions != null) {
            actions.replaceSlot(slot, pick)
            editSlot = null
            return
        }
        val custom = pick.custom
        if (custom != null) {
            if (onSelectCustom == null) return
            actions?.recordUse?.invoke(pick)
            onSelectCustom(custom)
        } else {
            if (reacting) actions?.recordUse?.invoke(pick)
            onSelectEmoji(pick.content)
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = SecondaryGroupedBg,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SecondaryText) },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 16.dp),
        ) {
            if (reacting) {
                QuickBarRow(
                    bar = EmojiPalette.orderedBar(palette),
                    editing = editing,
                    editSlot = editSlot,
                    onToggleEdit = { editing = !editing; editSlot = null },
                    onSlot = { slot -> if (editing) editSlot = slot else choose(slot) },
                )
                Spacer(Modifier.height(8.dp))
            }
            EmojiPickerGrid(
                sections = sections,
                names = catalog?.names.orEmpty(),
                onPick = ::choose,
                gridHeight = 320.dp,
            )
        }
    }
}

/** The Unicode catalog, null until it has been read (once per process). */
@Composable
internal fun rememberEmojiCatalog(): EmojiCatalog? {
    val context = LocalContext.current
    return produceState<EmojiCatalog?>(null) { value = EmojiCatalog.load(context) }.value
}

@Composable
internal fun rememberPalette(actions: ReactionActions?): State<EmojiPalette.State> {
    val empty = remember { kotlinx.coroutines.flow.MutableStateFlow(EmojiPalette.State()) }
    return (actions?.palette ?: empty).collectAsState()
}

@Composable
internal fun rememberLibrary(actions: ReactionActions?): State<EmojiListRepository.Library> {
    val empty = remember { kotlinx.coroutines.flow.MutableStateFlow(EmojiListRepository.Library()) }
    return (actions?.library ?: empty).collectAsState()
}
