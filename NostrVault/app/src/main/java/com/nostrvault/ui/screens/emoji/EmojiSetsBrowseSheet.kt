package com.nostrvault.ui.screens.emoji

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.emoji.EmojiSetBrowser
import com.nostrvault.ui.components.CustomEmojiImage
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/**
 * Browse other people's emoji sets (custom emoji plan §4.3): sets by people you follow, or everyone's from the last
 * month, or a pasted naddr / npub. Add or Remove rewrites your 10030. Reading costs nothing; only Add/Remove signs.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EmojiSetsBrowseSheet(viewModel: EmojiVaultViewModel, onDismiss: () -> Unit) {
    val state by viewModel.browse.collectAsState()
    val listed by viewModel.listed.collectAsState()
    val profiles by viewModel.profiles.collectAsState()
    var scope by remember { mutableStateOf(EmojiSetBrowser.Scope.FOLLOWS) }
    var pasted by remember { mutableStateOf("") }
    LaunchedEffect(scope) { viewModel.browse(scope) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
            Text("Emoji sets", color = PrimaryText, fontWeight = FontWeight.Bold, fontSize = 20.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(vertical = 8.dp)) {
                FilterChip(selected = scope == EmojiSetBrowser.Scope.FOLLOWS, onClick = { scope = EmojiSetBrowser.Scope.FOLLOWS }, label = { Text("People you follow") })
                FilterChip(selected = scope == EmojiSetBrowser.Scope.EVERYONE, onClick = { scope = EmojiSetBrowser.Scope.EVERYONE }, label = { Text("Everyone") })
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = pasted,
                    onValueChange = { pasted = it },
                    singleLine = true,
                    placeholder = { Text("Paste an naddr or npub") },
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = { viewModel.lookUp(pasted) }, enabled = pasted.isNotBlank()) { Text("Find") }
            }
            if (state.loading) {
                CircularProgressIndicator(Modifier.padding(24.dp).align(Alignment.CenterHorizontally))
            }
            state.note?.let { Text(it, color = SecondaryText, fontSize = 13.sp, modifier = Modifier.padding(vertical = 12.dp)) }
            LazyColumn(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
                items(state.found, key = { it.event.id }) { f ->
                    val inList = f.set.address in listed
                    Column(Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(f.set.title, color = PrimaryText, fontWeight = FontWeight.SemiBold, maxLines = 1)
                                Text(
                                    "by ${profiles[f.event.pubkey]?.bestName ?: f.event.pubkey.take(8)} · ${f.set.emojis.size} emoji",
                                    color = SecondaryText, fontSize = 12.sp,
                                )
                            }
                            TextButton(onClick = { viewModel.change(f.set.address, add = !inList, found = f) }) {
                                Text(if (inList) "Remove" else "Add")
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            f.set.emojis.take(PREVIEW).forEach { CustomEmojiImage(it, size = 28.dp) }
                            if (f.set.emojis.size > PREVIEW) {
                                Spacer(Modifier.size(4.dp))
                                Text("+${f.set.emojis.size - PREVIEW}", color = SecondaryText, fontSize = 12.sp)
                            }
                        }
                    }
                }
            }
        }
    }
}

private const val PREVIEW = 8
