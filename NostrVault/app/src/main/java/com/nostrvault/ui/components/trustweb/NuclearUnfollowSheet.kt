package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.service.NuclearUnfollow
import com.nostrvault.ui.navigation.NuclearUnfollowRequest
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.Surface1
import com.nostrvault.ui.theme.SuccessGreen

/**
 * Over the WOT tab while a Nuclear unfollow is under way: the card shows the
 * person and lights your follows who follow them; this bar says how many and
 * opens the list. Goes away once you pick someone else on the globe.
 */
@Composable
internal fun NuclearUnfollowOverlay(
    card: String?,
    litCount: Int?,
    accent: Color,
    name: (String) -> String,
    modifier: Modifier = Modifier,
) {
    val target by NuclearUnfollowRequest.target.collectAsState()
    var shown by remember(target) { mutableStateOf(false) }
    var listOpen by remember(target) { mutableStateOf(false) }
    LaunchedEffect(card, target) {
        if (target != null && card == target) shown = true
        // Picked someone else after the card opened on them: this one's over.
        else if (shown && target != null && card != target) NuclearUnfollowRequest.clear()
    }
    val person = target ?: return
    if (!shown || card != person) return
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = modifier
            .padding(horizontal = 16.dp)
            .background(Surface1.copy(alpha = 0.94f), RoundedCornerShape(16.dp))
            .padding(start = 14.dp, end = 6.dp, top = 6.dp, bottom = 6.dp),
    ) {
        Column(Modifier.weight(1f, fill = false)) {
            Text("Nuclear unfollow", color = ErrorRed, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            Text(
                when (litCount) {
                    null -> "Finding your follows who follow ${name(person)}…"
                    0 -> "None of your follows follow ${name(person)}"
                    1 -> "1 of your follows follows ${name(person)}"
                    else -> "$litCount of your follows follow ${name(person)}"
                },
                color = SecondaryText, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
        }
        TextButton(onClick = { listOpen = true }) { Text("Show list", color = accent, fontWeight = FontWeight.SemiBold) }
        TextButton(onClick = { NuclearUnfollowRequest.clear() }) { Text("Cancel", color = SecondaryText) }
    }
    if (listOpen) NuclearUnfollowSheet(person, accent, name, onDismiss = { listOpen = false })
}

/** The list: each person ticked; untick to keep them. Then the warning(s), the backup, the save, and Undo. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun NuclearUnfollowSheet(
    target: String,
    accent: Color,
    name: (String) -> String,
    onDismiss: () -> Unit,
    viewModel: NuclearUnfollowViewModel = hiltViewModel(),
) {
    LaunchedEffect(target) { viewModel.load(target) }
    val s by viewModel.state.collectAsState()
    val step = s.step
    ModalBottomSheet(
        onDismissRequest = { if (step != NuclearUnfollowViewModel.Step.SAVING) onDismiss() },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Surface1,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
            Text("Nuclear unfollow", color = PrimaryText, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            Text(
                "Unfollow ${name(target)} and the people you follow who follow them, so they stop reaching you. " +
                    "Untick anyone you want to keep.",
                color = SecondaryText, fontSize = 13.sp, modifier = Modifier.padding(top = 4.dp, bottom = 12.dp),
            )
            when (step) {
                NuclearUnfollowViewModel.Step.LOADING -> Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    Text("Finding your follows who follow them…", color = SecondaryText, fontSize = 13.sp, modifier = Modifier.padding(start = 10.dp))
                }
                NuclearUnfollowViewModel.Step.SAVING -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    StatusLine(if (s.backedUp) "Backup saved ✓" else "Saving a backup of your follow list…", done = s.backedUp)
                    if (s.backedUp) StatusLine("Publishing your new follow list…", done = false)
                }
                NuclearUnfollowViewModel.Step.DONE -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    StatusLine("Backup saved ✓", done = true)
                    StatusLine(
                        if (s.undone) "Undone: your follow list is back as it was." else NuclearUnfollow.firstWarning(s.unfollowed).replace("Unfollow", "Unfollowed"),
                        done = true,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
                        if (!s.undone) Button(
                            onClick = viewModel::undo, enabled = !s.undoing,
                            colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent, contentColor = accent),
                        ) { Text(if (s.undoing) "Undoing…" else "Undo") }
                        Button(onClick = { onDismiss(); NuclearUnfollowRequest.clear() }) { Text("Done") }
                    }
                }
                else -> PickList(s, name, accent, viewModel::toggle)
            }
            s.error?.let { Text(it, color = ErrorRed, fontSize = 13.sp, modifier = Modifier.padding(top = 10.dp)) }
            if (step == NuclearUnfollowViewModel.Step.PICK || step == NuclearUnfollowViewModel.Step.WARN || step == NuclearUnfollowViewModel.Step.WARN_AGAIN) {
                Button(
                    onClick = viewModel::next,
                    enabled = s.count > 0,
                    colors = ButtonDefaults.buttonColors(containerColor = ErrorRed),
                    modifier = Modifier.fillMaxWidth().padding(top = 14.dp),
                ) { Text(NuclearUnfollow.firstWarning(s.count), fontWeight = FontWeight.SemiBold) }
            }
        }
    }

    when (step) {
        NuclearUnfollowViewModel.Step.WARN -> AlertDialog(
            onDismissRequest = viewModel::cancelWarning,
            title = { Text(NuclearUnfollow.firstWarning(s.count)) },
            text = { Text("They come off your follow list in one change. A backup of your current list is saved first, and you can undo it.") },
            confirmButton = { TextButton(onClick = viewModel::next) { Text("Unfollow", color = ErrorRed) } },
            dismissButton = { TextButton(onClick = viewModel::cancelWarning) { Text("Cancel") } },
        )
        NuclearUnfollowViewModel.Step.WARN_AGAIN -> AlertDialog(
            onDismissRequest = viewModel::cancelWarning,
            title = { Text("Are you sure?") },
            text = { Text(NuclearUnfollow.secondWarning(s.count)) },
            confirmButton = { TextButton(onClick = viewModel::next) { Text("Yes, unfollow ${s.count}", color = ErrorRed) } },
            dismissButton = { TextButton(onClick = viewModel::cancelWarning) { Text("Cancel") } },
        )
        else -> Unit
    }
}

@Composable
private fun PickList(s: NuclearUnfollowViewModel.UiState, name: (String) -> String, accent: Color, onToggle: (String) -> Unit) {
    if (s.people.isEmpty()) {
        Text("You don't follow them, and none of your follows do.", color = SecondaryText, fontSize = 14.sp)
        return
    }
    Text("${s.count} of ${s.people.size} ticked", color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(bottom = 4.dp))
    if (!s.complete) {
        Text("Some relays didn't answer, so this list may miss a few people.", color = SecondaryText, fontSize = 12.sp)
    }
    LazyColumn(Modifier.fillMaxWidth().heightIn(max = 420.dp)) {
        items(s.people, key = { it }) { pubkey ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().clickable { onToggle(pubkey) }.padding(vertical = 2.dp),
            ) {
                Checkbox(
                    checked = pubkey in s.checked, onCheckedChange = { onToggle(pubkey) },
                    colors = CheckboxDefaults.colors(checkedColor = accent),
                )
                Text(
                    name(pubkey) + if (pubkey == s.target) " (the person you picked)" else "",
                    color = PrimaryText, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun StatusLine(text: String, done: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (!done) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp) else Spacer(Modifier.size(0.dp))
        Text(text, color = if (done) SuccessGreen else SecondaryText, fontSize = 14.sp, modifier = Modifier.padding(start = if (done) 0.dp else 8.dp))
    }
}
