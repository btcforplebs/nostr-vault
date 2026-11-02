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
 * Every kept version of one list, newest first: the app that saved it, when,
 * how many entries and what it changed against the one before, the wipes
 * flagged. Tap an older one to restore it, or the explained Merge entry on
 * top to bring back entries from several ([ListMergeScreen], mergeable lists
 * only). Twin of iOS `ListVersionsView`.
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
            item {
                val mergeable = ListVersionMerge.mergeKind(key.kind) != null && key.d.isEmpty() && versions.isNotEmpty()
                ListVersionsChoice(kind = key.kind, onMerge = if (mergeable) ({ merging = true }) else null)
            }
            itemsIndexed(versions, key = { _, v -> v.id }) { index, version ->
                val older = versions.getOrNull(index + 1)
                val wiped = older != null && ListShrinkRule.shrank(older, version)
                ListRow(onClick = if (index > 0) ({ restoring = version }) else null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(ListVersionText.title(version), color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f, fill = false))
                                if (index == 0) { Spacer(Modifier.width(6.dp)); Text("Now", color = SecondaryText, fontSize = 12.sp) }
                            }
                            Text(ListVersionText.detail(version, older), color = SecondaryText, fontSize = 13.sp)
                            if (wiped) Text(ListVersionText.WIPED, color = Color(0xFFFF9500), fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
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
