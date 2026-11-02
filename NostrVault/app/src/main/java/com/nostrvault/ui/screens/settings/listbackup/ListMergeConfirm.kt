package com.nostrvault.ui.screens.settings.listbackup

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.ListVersionMerge
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import kotlinx.coroutines.launch

/**
 * What Save does, in one or two lines, and Save: "Saves your follows as 22
 * entries: 18 back.", who a mute list mutes again, and a second tick when an
 * entry of the list now is unticked. Shared by the quick path and Review.
 * [onSave] returns what to tell the person when it wasn't saved.
 */
@Composable
internal fun ListMergeConfirm(
    kind: Int,
    name: String,
    rows: List<ListVersionMerge.Row>,
    review: Boolean,
    onReview: () -> Unit,
    onCancel: () -> Unit,
    onSave: suspend () -> String?,
) {
    val scope = rememberCoroutineScope()
    val sum = ListVersionMerge.mergeSummary(kind, rows)
    val leftOut = rows.count { it.status == ListVersionMerge.Status.REMOVED && !it.ticked }
    var shrinkOk by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var msg by remember { mutableStateOf("") }
    LaunchedEffect(sum.removed) { shrinkOk = false }
    val nothing = sum.added == 0 && sum.removed == 0

    ListRow(onClick = null) {
        Text(
            if (nothing) "Nothing to bring back." else ListVersionText.followConfirm(kind, sum.added, sum.removed)
                ?.let { "$it Signed by you; the list you have now stays in your vault's history." } ?:
                "Saves your ${name.lowercase()} as ${entryCount(sum.total)}: ${sum.added} back" +
                    (if (sum.removed > 0) ", ${sum.removed} taken out" else "") +
                    ". Signed by you; the list you have now stays in your vault's history.",
            color = PrimaryText,
            fontSize = 14.sp,
        )
        if (leftOut > 0) {
            Text("$leftOut you removed yourself later ${if (leftOut == 1) "stays" else "stay"} out.", color = SecondaryText, fontSize = 13.sp)
        }
        if (sum.remutes > 0) {
            Text("This mutes ${sum.remutes} ${if (sum.remutes == 1) "person" else "people"} again.", color = Color(0xFFFF9500), fontSize = 13.sp)
        }
        if (sum.removed > 0) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(checked = shrinkOk, onCheckedChange = { shrinkOk = it })
                Text("Yes, take ${entryCount(sum.removed)} out of the list I have now.", fontSize = 13.sp, color = PrimaryText)
            }
        }
        Spacer(Modifier.size(6.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Button(
                enabled = !busy && !nothing && sum.total > 0 && (sum.removed == 0 || shrinkOk),
                onClick = {
                    busy = true
                    msg = ""
                    scope.launch {
                        try {
                            msg = onSave().orEmpty()
                        } finally {
                            busy = false
                        }
                    }
                },
            ) { Text(if (busy) "Saving…" else "Save") }
            TextButton(enabled = !busy, onClick = onCancel) { Text("Cancel") }
            if (!review && !nothing) TextButton(enabled = !busy, onClick = onReview) { Text("Review") }
        }
        if (msg.isNotEmpty()) Text(msg, color = Color(0xFFFF9500), fontSize = 13.sp)
    }
}
