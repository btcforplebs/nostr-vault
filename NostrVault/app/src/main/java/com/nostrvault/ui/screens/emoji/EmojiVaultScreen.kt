package com.nostrvault.ui.screens.emoji

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.service.CustomEmoji
import com.nostrvault.service.emoji.EmojiVaultPage
import com.nostrvault.ui.components.CustomEmojiImage
import com.nostrvault.ui.components.GlassPill
import com.nostrvault.ui.components.GlassScaffold
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/**
 * The Vault tab's Emoji page (custom emoji plan §4.1, §4.3; Logen's pick 1): your 10030's sets, like Media but for
 * custom emoji. Each set shows its emoji, how many are saved in the vault, and a red dot on an image no server has.
 * Save copies (pick 2) stores them in the vault and publishes nothing public; Import zip fills in from a zip; Browse
 * sets adds or removes a set (rewrites the 10030, pick 5). Apple twin: `EmojiVaultView.swift`.
 */
@Composable
fun EmojiVaultScreen(
    modePill: @Composable () -> Unit,
    onProfileClick: (String) -> Unit,
    viewModel: EmojiVaultViewModel = hiltViewModel(),
) {
    val sets by viewModel.sets.collectAsState()
    val progress by viewModel.progress.collectAsState()
    val dead by viewModel.dead.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    val message by viewModel.message.collectAsState()
    var browsing by remember { mutableStateOf(false) }
    var opened by remember { mutableStateOf<Pair<EmojiVaultPage.Tile, String>?>(null) }
    val zipPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let(viewModel::importZip)
    }

    GlassScaffold(
        toolbar = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                modePill()
                Spacer(Modifier.weight(1f))
                GlassPill {
                    TextButton(onClick = { browsing = true }) { Text("Browse sets", color = PrimaryText) }
                }
            }
        },
    ) { padding ->
        LazyVerticalGrid(
            columns = GridCells.Adaptive(56.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                start = 12.dp, end = 12.dp, top = padding.calculateTopPadding() + 8.dp, bottom = padding.calculateBottomPadding() + 24.dp,
            ),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                SaveBar(
                    running = progress.running,
                    done = progress.done,
                    total = progress.total,
                    line = progress.error ?: progress.tally?.line(),
                    canSave = sets.any { it.listed && it.tiles.isNotEmpty() },
                    onSave = viewModel::saveCopies,
                    onZip = { zipPicker.launch(arrayOf("application/zip", "application/x-zip-compressed")) },
                )
            }
            if (sets.isEmpty()) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Text(
                        "No emoji sets yet. Browse sets to add one; its images stay links until you tap Save copies.",
                        color = SecondaryText, fontSize = 14.sp, modifier = Modifier.padding(vertical = 24.dp),
                    )
                }
            }
            for (block in sets) {
                item(span = { GridItemSpan(maxLineSpan) }, key = "h-${block.address}") {
                    SetHeader(
                        block,
                        authorName = profiles[block.author]?.bestName ?: block.author.take(8),
                        onAuthor = { if (block.author.isNotEmpty()) onProfileClick(block.author) },
                        onRemove = { viewModel.change(block.address, add = false) },
                        onAdd = { viewModel.change(block.address, add = true) },
                    )
                }
                items(block.tiles, key = { "t-${block.address}-${it.code}" }) { tile ->
                    EmojiTile(tile) { opened = tile to block.title }
                }
            }
            if (dead.isNotEmpty()) {
                item(span = { GridItemSpan(maxLineSpan) }, key = "dead") {
                    Column(Modifier.padding(top = 20.dp)) {
                        Text("Dead links (${dead.size})", color = PrimaryText, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                        Text(
                            "No server has these images, not even under their hash. A zip with the same files fills them in.",
                            color = SecondaryText, fontSize = 13.sp,
                        )
                        dead.take(MAX_DEAD_ROWS).forEach { d ->
                            Text(":${d.codes.joinToString(": :")}:  ${d.url}", color = SecondaryText, fontSize = 12.sp, maxLines = 1,
                                modifier = Modifier.padding(top = 4.dp))
                        }
                        if (dead.size > MAX_DEAD_ROWS) Text("and ${dead.size - MAX_DEAD_ROWS} more", color = SecondaryText, fontSize = 12.sp)
                    }
                }
            }
        }
    }

    opened?.let { (tile, setTitle) ->
        AlertDialog(
            onDismissRequest = { opened = null },
            confirmButton = { TextButton(onClick = { opened = null }) { Text("Done") } },
            title = { Text(":${tile.code}:") },
            text = {
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                    CustomEmojiImage(CustomEmoji(tile.code, tile.url), size = 128.dp)
                    Spacer(Modifier.size(12.dp))
                    Text(setTitle, color = SecondaryText, fontSize = 13.sp)
                    Text(
                        when {
                            tile.saved -> "Saved in your vault"
                            tile.dead -> "Dead link: no server has it"
                            else -> "Not saved: shown from its link"
                        },
                        color = if (tile.dead) ErrorRed else SecondaryText, fontSize = 13.sp,
                    )
                }
            },
        )
    }
    message?.let {
        AlertDialog(
            onDismissRequest = viewModel::dismissMessage,
            confirmButton = { TextButton(onClick = viewModel::dismissMessage) { Text("OK") } },
            text = { Text(it) },
        )
    }
    if (browsing) EmojiSetsBrowseSheet(viewModel = viewModel, onDismiss = { browsing = false })
}

@Composable
private fun SaveBar(
    running: Boolean,
    done: Int,
    total: Int,
    line: String?,
    canSave: Boolean,
    onSave: () -> Unit,
    onZip: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(bottom = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onSave, enabled = canSave && !running) { Text("Save copies") }
            TextButton(onClick = onZip, enabled = !running) { Text("Import zip") }
        }
        Text(
            "Save copies keeps each image in your vault and on your other devices. Nothing is posted.",
            color = SecondaryText, fontSize = 12.sp,
        )
        if (running) {
            LinearProgressIndicator(
                progress = { if (total > 0) done.toFloat() / total else 0f },
                modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
            )
            Text("$done of $total", color = SecondaryText, fontSize = 12.sp)
        }
        if (line != null) Text(line, color = PrimaryText, fontSize = 13.sp, modifier = Modifier.padding(top = 4.dp))
    }
}

@Composable
private fun SetHeader(
    block: EmojiVaultPage.SetBlock,
    authorName: String,
    onAuthor: () -> Unit,
    onRemove: () -> Unit,
    onAdd: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(top = 16.dp)) {
        Column(Modifier.weight(1f)) {
            Text(block.title, color = PrimaryText, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, maxLines = 1)
            Row {
                Text("by $authorName", color = SecondaryText, fontSize = 12.sp, modifier = Modifier.clickable(onClick = onAuthor))
                Spacer(Modifier.width(8.dp))
                Text(
                    "${block.savedCount} of ${block.tiles.size} saved" + if (!block.listed) " · not in your list" else "",
                    color = SecondaryText, fontSize = 12.sp,
                )
            }
        }
        Box {
            IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, contentDescription = "Set options", tint = SecondaryText) }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                if (block.listed) {
                    DropdownMenuItem(text = { Text("Remove from my list") }, onClick = { menu = false; onRemove() })
                } else {
                    DropdownMenuItem(text = { Text("Add to my list") }, onClick = { menu = false; onAdd() })
                }
            }
        }
    }
}

@Composable
private fun EmojiTile(tile: EmojiVaultPage.Tile, onClick: () -> Unit) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(56.dp)
            .clickable(onClick = onClick)
            .semantics {
                contentDescription = ":${tile.code}:, " + when {
                    tile.saved -> "saved"
                    tile.dead -> "dead link"
                    else -> "not saved"
                }
            },
    ) {
        CustomEmojiImage(CustomEmoji(tile.code, tile.url), size = 44.dp)
        if (tile.dead) {
            Box(Modifier.align(Alignment.TopEnd).size(8.dp).background(ErrorRed, CircleShape))
        } else if (!tile.saved) {
            Box(Modifier.align(Alignment.TopEnd).size(6.dp).background(SecondaryText.copy(alpha = 0.5f), CircleShape))
        }
    }
}

private const val MAX_DEAD_ROWS = 50
