package com.nostrvault.ui.screens.settings.listbackup

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
import com.nostrvault.service.ListHistory
import com.nostrvault.service.ListShrinkRule
import com.nostrvault.service.ListVersion
import com.nostrvault.service.ListVersionMerge
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText

/**
 * Every kept version of one list, newest first, with what changed against the
 * newest; tap an older one to restore it, or Merge to bring back entries
 * from several ([ListMergeScreen], mergeable lists only). Twin of iOS `ListVersionsView`.
 */
@Composable
internal fun ListVersionsPage(key: ListHistory.Key, viewModel: ListBackupViewModel, onBack: () -> Unit) {
    val groups by viewModel.groups.collectAsState()
    val versions = groups[key].orEmpty()
    var restoring by remember { mutableStateOf<ListVersion?>(null) }
    var merging by remember { mutableStateOf(false) }
    if (merging) {
        BackHandler { merging = false }
        ListMergeScreen(key = key, viewModel = viewModel, onBack = { merging = false })
        return
    }

    ListBackupScaffold(title = ListBackupFormat.title(key), onBack = onBack) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding() + 8.dp,
                bottom = padding.calculateBottomPadding() + 16.dp,
                start = 16.dp,
                end = 16.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            if (ListVersionMerge.mergeKind(key.kind) != null && key.d.isEmpty() && versions.isNotEmpty()) {
                item {
                    ListRow(onClick = { merging = true }) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Bring back entries from several versions", color = SecondaryText, fontSize = 13.sp, modifier = Modifier.weight(1f))
                            Text("Merge", color = Color(0xFF0A84FF), fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }
            itemsIndexed(versions, key = { _, v -> v.id }) { index, version ->
                val newest = versions.first()
                val wiped = index + 1 < versions.size && ListShrinkRule.shrank(versions[index + 1], version)
                ListRow(onClick = if (index > 0) ({ restoring = version }) else null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Row {
                                Text(ListBackupFormat.date(version.createdAt), color = PrimaryText, fontSize = 15.sp)
                                if (index == 0) { Spacer(Modifier.width(6.dp)); Text("Newest", color = SecondaryText, fontSize = 12.sp) }
                                if (wiped) { Spacer(Modifier.width(6.dp)); Text("Wipe", color = Color(0xFFFF9500), fontSize = 12.sp) }
                            }
                            val detail = if (index == 0) ListBackupFormat.count(version) else {
                                val (comeBack, go) = ListHistory.diff(version, newest)
                                "${ListBackupFormat.count(version)} · ${comeBack.size} not in newest, ${go.size} added since"
                            }
                            Text(detail, color = SecondaryText, fontSize = 13.sp)
                        }
                        if (index > 0) Text("Restore", color = Color(0xFF0A84FF), fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
            item {
                Text(
                    "Restoring signs the old version again as a new list. Your vault keeps the one it replaces.",
                    color = SecondaryText,
                    fontSize = 12.sp,
                )
            }
        }
    }
    restoring?.let { old -> ListRestoreDialog(old = old, viewModel = viewModel, onClose = { restoring = null }) }
}
