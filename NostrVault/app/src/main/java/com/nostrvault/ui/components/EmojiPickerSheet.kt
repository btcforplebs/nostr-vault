package com.nostrvault.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.nostrvault.data.local.EmojiPalette
import com.nostrvault.data.local.ReactionPick
import com.nostrvault.service.CustomEmoji
import com.nostrvault.service.EmojiListRepository
import com.nostrvault.ui.theme.*

/**
 * Emoji reaction picker bottom sheet.
 * Port of iOS EmojiPickerView with quick reactions, categories, and custom input.
 *
 * With [onSelectCustom] it is the reaction picker: the quick bar (which
 * can be edited), Recents, the account's own custom emoji and each set it
 * added come first. Without it (choosing the default reaction) it offers
 * Unicode only, as before.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EmojiPickerSheet(
    sheetState: SheetState,
    onDismiss: () -> Unit,
    onSelectEmoji: (String) -> Unit,
    onSelectCustom: ((CustomEmoji) -> Unit)? = null,
) {
    val colors = LocalNostrVaultColors.current
    val haptic = LocalHapticFeedback.current
    val actions = LocalReactionActions.current
    val reacting = onSelectCustom != null && actions != null
    var searchQuery by remember { mutableStateOf("") }
    var customEmoji by remember { mutableStateOf("") }
    // The quick-bar slot being changed, while editing it.
    var editing by remember { mutableStateOf(false) }
    var editSlot by remember { mutableStateOf<ReactionPick?>(null) }

    val emptyPalette = remember { kotlinx.coroutines.flow.MutableStateFlow(EmojiPalette.State()) }
    val emptyLibrary = remember { kotlinx.coroutines.flow.MutableStateFlow(EmojiListRepository.Library()) }
    val palette by (actions?.palette ?: emptyPalette).collectAsState()
    val library by (actions?.library ?: emptyLibrary).collectAsState()
    LaunchedEffect(reacting) { if (reacting) actions?.refreshLibrary?.invoke() }

    val tabs = remember(palette, library, reacting) { EmojiPickerTabs.build(emojiCategories(), palette, library, reacting) }
    var selectedTab by remember { mutableIntStateOf(0) }
    val tabIndex = selectedTab.coerceIn(0, (tabs.size - 1).coerceAtLeast(0))

    val displayed = remember(searchQuery, tabIndex, tabs) {
        if (searchQuery.isNotBlank()) EmojiPickerTabs.search(tabs, searchQuery) else tabs.getOrNull(tabIndex)?.picks.orEmpty()
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
                .padding(horizontal = 20.dp)
                .padding(bottom = 32.dp),
        ) {
            // Title
            Text(
                text = "React",
                color = PrimaryText,
                fontWeight = FontWeight.Bold,
                fontSize = 20.sp,
                modifier = Modifier.align(Alignment.CenterHorizontally),
            )

            Spacer(Modifier.height(16.dp))

            if (reacting) {
                QuickBarRow(
                    bar = EmojiPalette.orderedBar(palette),
                    editing = editing,
                    editSlot = editSlot,
                    onToggleEdit = { editing = !editing; editSlot = null },
                    onSlot = { slot -> if (editing) editSlot = slot else choose(slot) },
                )
            } else {
                // Quick reactions row
                Row(
                    horizontalArrangement = Arrangement.SpaceEvenly,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    for (emoji in QUICK_REACTIONS) {
                        Text(
                            text = emoji,
                            fontSize = 28.sp,
                            modifier = Modifier
                                .clickable { choose(ReactionPick(emoji)) }
                                .padding(4.dp),
                        )
                    }
                }
            }

            Spacer(Modifier.height(12.dp))

            // Custom emoji input
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                OutlinedTextField(
                    value = customEmoji,
                    onValueChange = { customEmoji = it },
                    placeholder = { Text("Custom emoji", color = PlaceholderText) },
                    singleLine = true,
                    shape = RoundedCornerShape(10.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = colors.primary,
                        unfocusedBorderColor = SeparatorColor,
                        cursorColor = colors.primary,
                        focusedTextColor = PrimaryText,
                        unfocusedTextColor = PrimaryText,
                    ),
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(8.dp))
                Button(
                    onClick = {
                        if (customEmoji.isNotBlank()) choose(ReactionPick(customEmoji.trim()))
                    },
                    enabled = customEmoji.isNotBlank(),
                    shape = RoundedCornerShape(10.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = colors.primary,
                        contentColor = PrimaryText,
                    ),
                ) {
                    Text("React", fontWeight = FontWeight.SemiBold)
                }
            }

            Spacer(Modifier.height(12.dp))

            // Search
            OutlinedTextField(
                value = searchQuery,
                onValueChange = { searchQuery = it },
                placeholder = { Text("Search emoji...", color = PlaceholderText) },
                leadingIcon = {
                    Icon(
                        NostrVaultIcons.Search,
                        contentDescription = null,
                        tint = SecondaryText,
                        modifier = Modifier.size(18.dp),
                    )
                },
                singleLine = true,
                shape = RoundedCornerShape(10.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.primary,
                    unfocusedBorderColor = SeparatorColor,
                    cursorColor = colors.primary,
                    focusedTextColor = PrimaryText,
                    unfocusedTextColor = PrimaryText,
                ),
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(12.dp))

            // Tabs: Recents, your emoji and each set first when reacting, then the categories
            if (searchQuery.isBlank() && tabs.isNotEmpty()) {
                ScrollableTabRow(
                    selectedTabIndex = tabIndex,
                    containerColor = SecondaryGroupedBg,
                    contentColor = PrimaryText,
                    edgePadding = 0.dp,
                    divider = {},
                ) {
                    tabs.forEachIndexed { index, tab ->
                        Tab(
                            selected = tabIndex == index,
                            onClick = { selectedTab = index },
                            modifier = Modifier.semantics { contentDescription = tab.name },
                            text = { ReactionGlyph(tab.icon.content, tab.icon.custom, fontSize = 18.sp) },
                        )
                    }
                }

                Spacer(Modifier.height(8.dp))
            }

            // Emoji grid
            LazyVerticalGrid(
                columns = GridCells.Adaptive(minSize = 40.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(260.dp),
            ) {
                items(displayed) { pick ->
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .clickable { choose(pick) }
                            .semantics { contentDescription = pick.content }
                            .padding(4.dp),
                    ) {
                        ReactionGlyph(pick.content, pick.custom, fontSize = 26.sp)
                    }
                }
            }
        }
    }
}

private val QUICK_REACTIONS = listOf("\u2764\uFE0F", "\uD83D\uDC4D", "\uD83D\uDD25", "\uD83D\uDE02", "\uD83D\uDE2E", "\uD83D\uDE22", "\uD83C\uDF89", "\uD83D\uDE80")

internal data class EmojiCategory(
    val name: String,
    val icon: String,
    val emojis: List<String>,
)

internal fun emojiCategories(): List<EmojiCategory> = listOf(
    EmojiCategory(
        name = "Smileys",
        icon = "\uD83D\uDE00",
        emojis = listOf(
            "\uD83D\uDE00", "\uD83D\uDE01", "\uD83D\uDE02", "\uD83E\uDD23", "\uD83D\uDE03", "\uD83D\uDE04", "\uD83D\uDE05", "\uD83D\uDE06",
            "\uD83D\uDE09", "\uD83D\uDE0A", "\uD83D\uDE0B", "\uD83D\uDE0E", "\uD83D\uDE0D", "\uD83E\uDD29", "\uD83D\uDE18", "\uD83D\uDE17",
            "\uD83E\uDD14", "\uD83E\uDD28", "\uD83D\uDE10", "\uD83D\uDE11", "\uD83D\uDE36", "\uD83D\uDE44", "\uD83D\uDE0F", "\uD83D\uDE23",
            "\uD83D\uDE25", "\uD83E\uDD7A", "\uD83D\uDE22", "\uD83D\uDE2D", "\uD83D\uDE24", "\uD83D\uDE20", "\uD83D\uDE21", "\uD83E\uDD2C",
            "\uD83E\uDD2F", "\uD83D\uDE33", "\uD83E\uDD75", "\uD83E\uDD76", "\uD83D\uDE31", "\uD83D\uDE28", "\uD83D\uDE30", "\uD83D\uDE25",
            "\uD83D\uDE13", "\uD83E\uDD17", "\uD83E\uDD2D", "\uD83E\uDD2B", "\uD83E\uDD25", "\uD83D\uDE42", "\uD83E\uDD10", "\uD83E\uDD27",
        ),
    ),
    EmojiCategory(
        name = "Hearts & Hands",
        icon = "\u2764\uFE0F",
        emojis = listOf(
            "\u2764\uFE0F", "\uD83E\uDDE1", "\uD83D\uDC9B", "\uD83D\uDC9A", "\uD83D\uDC99", "\uD83D\uDC9C", "\uD83E\uDD0E", "\uD83D\uDDA4",
            "\uD83E\uDD0D", "\uD83D\uDC95", "\uD83D\uDC9E", "\uD83D\uDC93", "\uD83D\uDC97", "\uD83D\uDC96", "\uD83D\uDC98", "\uD83D\uDC9D",
            "\uD83D\uDC4D", "\uD83D\uDC4E", "\u270A", "\uD83E\uDD1B", "\uD83E\uDD1C", "\uD83D\uDC4A", "\uD83D\uDC4F", "\uD83D\uDE4C",
            "\uD83D\uDC50", "\uD83E\uDD32", "\uD83E\uDD1D", "\uD83D\uDE4F", "\u270D\uFE0F", "\uD83D\uDC85", "\uD83E\uDD33", "\uD83D\uDCAA",
            "\uD83D\uDC4B", "\uD83E\uDD1A", "\uD83D\uDD90\uFE0F", "\u270B", "\uD83D\uDD96", "\uD83D\uDC4C", "\u270C\uFE0F", "\uD83E\uDD1E",
            "\uD83E\uDD1F", "\uD83E\uDD18", "\uD83E\uDD19", "\uD83D\uDC48", "\uD83D\uDC49", "\uD83D\uDC46", "\uD83D\uDC47", "\u261D\uFE0F",
        ),
    ),
    EmojiCategory(
        name = "Fun & Activities",
        icon = "\uD83C\uDF89",
        emojis = listOf(
            "\uD83C\uDF89", "\uD83C\uDF8A", "\uD83C\uDFC6", "\uD83E\uDD47", "\uD83E\uDD48", "\uD83E\uDD49", "\u26BD", "\uD83C\uDFC0",
            "\uD83C\uDFC8", "\u26BE", "\uD83C\uDFBE", "\uD83C\uDFD0", "\uD83C\uDFC9", "\uD83C\uDFB1", "\uD83C\uDFB3", "\uD83C\uDFAF",
            "\uD83C\uDFAE", "\uD83D\uDD79\uFE0F", "\uD83C\uDFB2", "\uD83C\uDFB0", "\uD83C\uDFAD", "\uD83C\uDFA8", "\uD83C\uDFB5", "\uD83C\uDFB6",
            "\uD83C\uDFB9", "\uD83C\uDFB7", "\uD83C\uDFBA", "\uD83C\uDFBB", "\uD83C\uDFBC", "\uD83E\uDD41", "\uD83D\uDE80", "\uD83D\uDEF8",
            "\uD83C\uDF1F", "\u2B50", "\uD83C\uDF1E", "\uD83C\uDF08", "\u2604\uFE0F", "\uD83D\uDCA5", "\uD83D\uDD25", "\uD83C\uDF0A",
            "\uD83C\uDF0D", "\uD83C\uDF0E", "\uD83C\uDF0F", "\uD83C\uDF15", "\uD83C\uDF19", "\u2728", "\uD83D\uDCAB", "\uD83D\uDCB0",
        ),
    ),
    EmojiCategory(
        name = "Animals & Nature",
        icon = "\uD83D\uDC36",
        emojis = listOf(
            "\uD83D\uDC36", "\uD83D\uDC31", "\uD83D\uDC2D", "\uD83D\uDC39", "\uD83D\uDC30", "\uD83E\uDD8A", "\uD83D\uDC3B", "\uD83D\uDC3C",
            "\uD83D\uDC28", "\uD83D\uDC2F", "\uD83E\uDD81", "\uD83D\uDC2E", "\uD83D\uDC37", "\uD83D\uDC38", "\uD83D\uDC35", "\uD83D\uDE48",
            "\uD83D\uDE49", "\uD83D\uDE4A", "\uD83D\uDC12", "\uD83D\uDC14", "\uD83D\uDC27", "\uD83D\uDC26", "\uD83D\uDC24", "\uD83D\uDC23",
            "\uD83E\uDD86", "\uD83E\uDD85", "\uD83E\uDD89", "\uD83E\uDD87", "\uD83D\uDC3A", "\uD83D\uDC17", "\uD83D\uDC34", "\uD83E\uDD84",
            "\uD83D\uDC1D", "\uD83D\uDC1B", "\uD83E\uDD8B", "\uD83D\uDC0C", "\uD83D\uDC1A", "\uD83D\uDC1E", "\uD83D\uDC1C", "\uD83E\uDD97",
            "\uD83C\uDF3A", "\uD83C\uDF3B", "\uD83C\uDF37", "\uD83C\uDF39", "\uD83C\uDF3C", "\uD83C\uDF3E", "\uD83C\uDF32", "\uD83C\uDF33",
        ),
    ),
    EmojiCategory(
        name = "Food & Drink",
        icon = "\uD83C\uDF54",
        emojis = listOf(
            "\uD83C\uDF4E", "\uD83C\uDF4F", "\uD83C\uDF4A", "\uD83C\uDF4B", "\uD83C\uDF4C", "\uD83C\uDF49", "\uD83C\uDF47", "\uD83C\uDF53",
            "\uD83C\uDF48", "\uD83C\uDF51", "\uD83C\uDF52", "\uD83C\uDF50", "\uD83E\uDD5D", "\uD83C\uDF45", "\uD83E\uDD51", "\uD83C\uDF46",
            "\uD83E\uDD55", "\uD83C\uDF3D", "\uD83C\uDF36\uFE0F", "\uD83E\uDD52", "\uD83E\uDD66", "\uD83C\uDF5E", "\uD83E\uDD50", "\uD83E\uDD56",
            "\uD83C\uDF54", "\uD83C\uDF55", "\uD83C\uDF2E", "\uD83C\uDF2F", "\uD83E\uDD59", "\uD83E\uDD5A", "\uD83C\uDF73", "\uD83E\uDD58",
            "\uD83C\uDF72", "\uD83E\uDD63", "\uD83E\uDD57", "\uD83C\uDF7F", "\uD83C\uDF70", "\uD83C\uDF82", "\uD83C\uDF69", "\uD83C\uDF66",
            "\u2615", "\uD83C\uDF75", "\uD83C\uDF7A", "\uD83C\uDF7B", "\uD83E\uDD42", "\uD83C\uDF77", "\uD83E\uDD43", "\uD83C\uDF78",
        ),
    ),
)
