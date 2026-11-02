package com.nostrvault.ui.screens.settings.listbackup

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.ListBackupService
import com.nostrvault.service.ListHistory
import com.nostrvault.service.ListShrinkRule
import com.nostrvault.service.ListVersion
import com.nostrvault.ui.theme.SecondaryText
import kotlinx.coroutines.launch

/**
 * Restore one kept version of a list: shows what comes back and what goes,
 * against the newest list fetched when this opens, and publishes only on the
 * tap. Twin of iOS `ListRestoreView`.
 */
@Composable
internal fun ListRestoreDialog(old: ListVersion, viewModel: ListBackupViewModel, onClose: () -> Unit) {
    val name = ListShrinkRule.name(old.kind)
    var preview by remember(old.id) { mutableStateOf<ListBackupService.Preview?>(null) }
    var problem by remember(old.id) { mutableStateOf<String?>(null) }
    var working by remember(old.id) { mutableStateOf(false) }
    var done by remember(old.id) { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(old.id) {
        viewModel.preview(old)
            .onSuccess { preview = it }
            .onFailure { problem = it.message ?: "Your newest $name can't be checked. Nothing was changed." }
    }

    AlertDialog(
        onDismissRequest = { if (!working) onClose() },
        title = { Text("Restore $name") },
        text = {
            Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
                Text("Your $name from ${ListBackupFormat.date(old.createdAt)}, ${ListBackupFormat.count(old)}.")
                Spacer(Modifier.size(10.dp))
                val shown = preview
                when {
                    done -> Text("Restored. Your vault still keeps the list it replaced.", color = Color(0xFF34C759))
                    problem != null -> Text(problem!!, color = Color(0xFFFF9500))
                    shown == null -> Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(8.dp))
                        Text("Checking your newest $name…", color = SecondaryText)
                    }
                    else -> {
                        Changes("Comes back", shown.comeBack)
                        Changes("Goes", shown.go)
                        if (shown.replacesPrivate) {
                            Text(
                                "Your private items go back to the ones from ${ListBackupFormat.date(old.createdAt)}. " +
                                    "Private items added since then are removed.",
                                color = Color(0xFFFF9500),
                            )
                            Spacer(Modifier.size(8.dp))
                        }
                        if (shown.comeBack.isEmpty() && shown.go.isEmpty()) {
                            Text(if (shown.replacesPrivate) "Same public items as your newest $name." else "Same items as your newest $name.", color = SecondaryText)
                        }
                    }
                }
            }
        },
        confirmButton = {
            if (!done) {
                TextButton(
                    enabled = preview != null && problem == null && !working,
                    onClick = {
                        val shown = preview ?: return@TextButton
                        working = true
                        scope.launch {
                            val message = viewModel.restore(old, shown)
                            working = false
                            if (message == null) done = true else problem = message
                        }
                    },
                ) { Text("Restore") }
            }
        },
        dismissButton = {
            TextButton(enabled = !working, onClick = onClose) { Text(if (done) "Done" else "Cancel") }
        },
    )
}

@Composable
private fun Changes(title: String, items: Set<String>) {
    if (items.isEmpty()) return
    Text("$title (${items.size})", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
    items.sorted().take(50).forEach { key ->
        Text(ListHistory.label(key), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, color = SecondaryText)
    }
    if (items.size > 50) Text("and ${items.size - 50} more", fontSize = 12.sp, color = SecondaryText)
    Spacer(Modifier.size(8.dp))
}
