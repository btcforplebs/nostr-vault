package com.nostrvault.ui.screens.settings.listbackup

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.service.ListHistory
import com.nostrvault.service.ListVersionMerge
import com.nostrvault.service.ListWipeAlarmText
import com.nostrvault.service.ListVersion
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

private val Orange = Color(0xFFFF9500)

/**
 * On the vault dashboard: a list another app just clobbered, from the vault's
 * history and the wipe-alarm rule (docs/LIST_WIPE_ALARM.md): emptied, swapped
 * for other entries, drained in steps, or cut by more than half. "Your follows
 * went from 412 to 3 on 4 Nov. Changed by Amethyst." Recover asks first
 * (ListRestoreDialog); Merge opens List backups' merge for the lists it can
 * merge; "Keep the new list" hides it for good. Nothing is ever restored or
 * published on its own. Twin of iOS `ListWipeBanner`.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ListShrinkBanner(viewModel: ListBackupViewModel = hiltViewModel()) {
    val wipes by viewModel.wipes.collectAsState()
    val account by viewModel.account.collectAsState()
    var restoring by remember { mutableStateOf<ListVersion?>(null) }
    var merging by remember { mutableStateOf<ListHistory.Key?>(null) }
    LaunchedEffect(account) { viewModel.load() }

    if (wipes.isNotEmpty()) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            wipes.take(3).forEach { (key, alarm) ->
                val name = ListBackupFormat.title(key).lowercase()
                val canMerge = ListVersionMerge.mergeKind(key.kind) != null && key.d.isEmpty()
                Surface(
                    shape = RoundedCornerShape(12.dp),
                    color = Orange.copy(alpha = 0.1f),
                    border = BorderStroke(1.dp, Orange.copy(alpha = 0.4f)),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(Modifier.padding(14.dp)) {
                        Row(verticalAlignment = Alignment.Top) {
                            Icon(Icons.Filled.Warning, contentDescription = null, tint = Orange, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(12.dp))
                            Column {
                                Text(
                                    ListWipeAlarmText.headline(alarm, name, ListBackupFormat.day(alarm.after.createdAt)),
                                    color = PrimaryText,
                                    fontWeight = FontWeight.SemiBold,
                                    fontSize = 15.sp,
                                )
                                Text(
                                    "${ListWipeAlarmText.changedBy(alarm)} Your vault kept the list from before. If you made this change, keep the new list.",
                                    color = SecondaryText,
                                    fontSize = 14.sp,
                                )
                            }
                        }
                        Spacer(Modifier.size(10.dp))
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Button(onClick = { restoring = alarm.before }) { Text("Recover") }
                            if (canMerge) OutlinedButton(onClick = { merging = key }) { Text("Merge") }
                            OutlinedButton(onClick = { viewModel.dismiss(alarm) }) { Text("Keep the new list") }
                        }
                    }
                }
            }
        }
    }
    restoring?.let { old -> ListRestoreDialog(old = old, viewModel = viewModel, onClose = { restoring = null }) }
    merging?.let { key ->
        Dialog(onDismissRequest = { merging = null }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Surface(Modifier.fillMaxSize()) {
                ListMergeScreen(key = key, viewModel = viewModel, onBack = { merging = null })
            }
        }
    }
}
