package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.nostrvault.data.model.FeedMenuSettings
import com.nostrvault.data.model.FeedMode
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.SeparatorColor
import com.nostrvault.ui.theme.WindowBackground

// iOS list rows: 44pt, hairline separators inset to the text.
private val RowHeight = 44.dp
private val SeparatorInset = 16.dp + 20.dp + 12.dp + 24.dp + 12.dp

/**
 * Show, hide and reorder the feeds in the feed picker (iOS #303,
 * FeedMenuEditor). Following is the home feed, so it is always shown. Each
 * change is saved as it is made; [onSaved] gets the hidden feeds, so the
 * caller can leave a feed that was just hidden.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeedMenuEditor(
    onSaved: (hidden: Set<FeedMode>) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val order = remember { mutableStateListOf<FeedMode>().apply { addAll(FeedMenuSettings.menuOrder()) } }
    var hidden by remember { mutableStateOf(FeedMenuSettings.hidden()) }
    var dragging by remember { mutableStateOf<FeedMode?>(null) }
    var dragOffset by remember { mutableFloatStateOf(0f) }
    val rowPx = with(LocalDensity.current) { RowHeight.toPx() }

    fun save() {
        FeedMenuSettings.save(order.toList(), hidden)
        onSaved(hidden)
    }

    fun move(mode: FeedMode, by: Int): Boolean {
        val from = order.indexOf(mode)
        val to = from + by
        if (from < 0 || to !in order.indices) return false
        order.add(to, order.removeAt(from))
        return true
    }

    // A sheet, as on iOS (FeedView .sheet), not a full-screen page.
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = WindowBackground,
        contentColor = PrimaryText,
        shape = RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp),
        dragHandle = null,
    ) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding()) {
            Box(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 8.dp)) {
                Text(
                    "Edit Feeds",
                    color = PrimaryText,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.align(Alignment.Center),
                )
                TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.CenterEnd)) {
                    Text("Done", color = colors.primary, fontWeight = FontWeight.SemiBold)
                }
            }

            Column(
                Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState(), enabled = dragging == null)
                    .padding(horizontal = 16.dp),
            ) {
                Column(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(SecondaryGroupedBg),
                ) {
                    for ((index, mode) in order.withIndex()) key(mode) {
                        val isLast = index == order.lastIndex
                        val isPinned = mode == FeedMenuSettings.PINNED
                        val isShown = isPinned || mode !in hidden
                        val isDragged = dragging == mode
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(RowHeight)
                                .zIndex(if (isDragged) 1f else 0f)
                                .graphicsLayer {
                                    translationY = if (isDragged) dragOffset else 0f
                                    shadowElevation = if (isDragged) 8.dp.toPx() else 0f
                                }
                                .background(SecondaryGroupedBg)
                                .drawBehind {
                                    if (!isLast && !isDragged) {
                                        val y = size.height - 0.5.dp.toPx() / 2
                                        drawLine(SeparatorColor, Offset(SeparatorInset.toPx(), y), Offset(size.width, y), 0.5.dp.toPx())
                                    }
                                }
                                .clickable(enabled = !isPinned) {
                                    hidden = if (isShown) hidden + mode else hidden - mode
                                    save()
                                }
                                .semantics(mergeDescendants = true) {
                                    contentDescription = mode.displayName
                                    stateDescription = when {
                                        isPinned -> "Always shown"
                                        isShown -> "Shown"
                                        else -> "Hidden"
                                    }
                                    customActions = listOf(
                                        CustomAccessibilityAction("Move up") { move(mode, -1).also { if (it) save() } },
                                        CustomAccessibilityAction("Move down") { move(mode, 1).also { if (it) save() } },
                                    )
                                }
                                .padding(start = 16.dp),
                        ) {
                            Icon(
                                imageVector = if (isShown) NostrVaultIcons.CheckCircle else NostrVaultIcons.CircleOutline,
                                contentDescription = null,
                                tint = if (isShown && !isPinned) colors.primary else SecondaryText,
                                modifier = Modifier.size(20.dp),
                            )
                            Spacer(Modifier.width(12.dp))
                            Box(Modifier.width(24.dp), contentAlignment = Alignment.Center) {
                                Icon(
                                    imageVector = mode.icon,
                                    contentDescription = null,
                                    tint = if (isShown) colors.primary else SecondaryText,
                                    modifier = Modifier.size(16.dp),
                                )
                            }
                            Spacer(Modifier.width(12.dp))
                            Text(
                                mode.displayName,
                                color = if (isShown) PrimaryText else SecondaryText,
                                fontSize = 17.sp,
                                modifier = Modifier.weight(1f),
                            )
                            // The handle takes the drag, so a tap anywhere
                            // else on the row still shows or hides the feed.
                            Box(
                                contentAlignment = Alignment.Center,
                                modifier = Modifier
                                    .size(RowHeight)
                                    // A tap on the handle is not a tap on the
                                    // row: it would show or hide the feed.
                                    .pointerInput(Unit) { detectTapGestures { } }
                                    .pointerInput(mode) {
                                        detectDragGestures(
                                            onDragStart = {
                                                dragging = mode
                                                dragOffset = 0f
                                            },
                                            onDrag = { change, amount ->
                                                change.consume()
                                                dragOffset += amount.y
                                                // Swap with the neighbour once past half its height.
                                                while (dragOffset > rowPx / 2 && move(mode, 1)) dragOffset -= rowPx
                                                while (dragOffset < -rowPx / 2 && move(mode, -1)) dragOffset += rowPx
                                            },
                                            onDragEnd = {
                                                dragging = null
                                                dragOffset = 0f
                                                save()
                                            },
                                            onDragCancel = {
                                                dragging = null
                                                dragOffset = 0f
                                                save()
                                            },
                                        )
                                    },
                            ) {
                                Icon(
                                    imageVector = NostrVaultIcons.DragHandle,
                                    contentDescription = null,
                                    tint = SecondaryText,
                                    modifier = Modifier.size(20.dp),
                                )
                            }
                        }
                    }
                }

                Text(
                    "Tap a feed to show or hide it. Drag the handle to change the order. Following is always shown.",
                    color = SecondaryText,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )

                val isDefault = order.toList() == FeedMode.entries && hidden.isEmpty()
                Box(
                    Modifier
                        .padding(top = 16.dp, bottom = 24.dp)
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(SecondaryGroupedBg)
                        .clickable(enabled = !isDefault) {
                            order.clear()
                            order.addAll(FeedMode.entries)
                            hidden = emptySet()
                            save()
                        }
                        .padding(horizontal = 16.dp, vertical = 16.dp),
                ) {
                    Text(
                        "Reset to Default",
                        color = if (isDefault) SecondaryText else colors.primary,
                        fontSize = 16.sp,
                    )
                }
            }
        }
    }
}
