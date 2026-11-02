package com.nostrvault.ui.screens.settings.listbackup

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.service.ListBackupService
import com.nostrvault.service.ListHistory
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.WindowBackground

/**
 * List backups: every list the vault keeps old versions of for the active
 * account, one row each; a row opens its versions (ListVersionsPage).
 * Twin of iOS `ListBackupView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ListBackupScreen(onBack: () -> Unit, viewModel: ListBackupViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsState()
    val groups by viewModel.groups.collectAsState()
    val account by viewModel.account.collectAsState()
    var open by remember { mutableStateOf<ListHistory.Key?>(null) }
    LaunchedEffect(account) {
        open = null
        viewModel.load()
    }

    val opened = open
    if (opened != null) {
        BackHandler { open = null }
        ListVersionsPage(key = opened, viewModel = viewModel, onBack = { open = null })
        return
    }

    ListBackupScaffold(title = "List backups", onBack = onBack) { padding ->
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
                Text(
                    "Your vault keeps the last 20 versions of each of your lists, and the one from before a wipe. " +
                        "Pick a list to see its versions and restore one.",
                    color = SecondaryText,
                    fontSize = 14.sp,
                    modifier = Modifier.padding(bottom = 8.dp),
                )
            }
            if (groups.isEmpty()) {
                item {
                    when (state) {
                        ListBackupService.State.UNAVAILABLE ->
                            Text("Your vault didn't answer. Make sure it is running, then open this page again.", color = SecondaryText)
                        ListBackupService.State.LOADED ->
                            Text("No list versions kept yet. They are kept from the next time a list changes.", color = SecondaryText)
                        else -> Row(verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                            Spacer(Modifier.width(8.dp))
                            Text("Reading your vault…", color = SecondaryText)
                        }
                    }
                }
            } else {
                items(groups.keys.sorted(), key = { "${it.kind}:${it.d}" }) { key ->
                    val versions = groups[key].orEmpty()
                    ListRow(onClick = { open = key }) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(ListBackupFormat.title(key), color = PrimaryText, fontSize = 16.sp)
                            if (ListHistory.latestWipe(versions) != null) {
                                Spacer(Modifier.width(6.dp))
                                Icon(Icons.Filled.Warning, contentDescription = "Wiped", tint = Color(0xFFFF9500), modifier = Modifier.size(16.dp))
                            }
                        }
                        val last = versions.firstOrNull()?.let { ", last changed ${ListBackupFormat.date(it.createdAt)}" }.orEmpty()
                        Text("${versions.size} ${if (versions.size == 1) "version" else "versions"}$last", color = SecondaryText, fontSize = 13.sp)
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ListBackupScaffold(
    title: String,
    onBack: () -> Unit,
    content: @Composable (PaddingValues) -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(NostrVaultIcons.Back, contentDescription = "Back") }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                ),
            )
        },
        containerColor = WindowBackground,
        content = content,
    )
}

@Composable
internal fun ListRow(onClick: (() -> Unit)?, content: @Composable () -> Unit) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = SecondaryGroupedBg,
        modifier = Modifier.fillMaxWidth().let { if (onClick != null) it.clickable(onClick = onClick) else it },
    ) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 11.dp)) { content() }
    }
}
