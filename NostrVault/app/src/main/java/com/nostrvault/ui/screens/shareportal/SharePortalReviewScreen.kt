package com.nostrvault.ui.screens.shareportal

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.shareportal.ShareAction
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.ui.theme.*

/**
 * `nostrvault://shareportal`: the review card for what was shared from
 * another app. Nothing the share sheet queued is published until a button
 * here is tapped. Twin: SharePortalReviewSheet.swift.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SharePortalReviewScreen(
    onBack: () -> Unit,
    viewModel: SharePortalReviewViewModel = hiltViewModel(),
) {
    val items by viewModel.items.collectAsState()
    val busy by viewModel.busy.collectAsState()
    val active by viewModel.activeNpub.collectAsState()
    val current = items.firstOrNull()
    Scaffold(
        containerColor = Surface0,
        topBar = {
            TopAppBar(
                title = { Text(if (items.size > 1) "Shared to Nostr Vault (${items.size})" else "Shared to Nostr Vault") },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Surface0),
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (current == null) {
                Text("Nothing waiting. Share a link or some text to Nostr Vault from another app.", color = SecondaryText)
                return@Column
            }
            key(current.id) { ReviewCard(current, busy, active, viewModel) }
        }
    }
}

@Composable
private fun ReviewCard(intent: ShareIntent, busy: Boolean, active: String, viewModel: SharePortalReviewViewModel) {
    if (intent.isStale(System.currentTimeMillis() / 1000)) {
        Text("Shared more than a week ago.", color = SecondaryText)
    }
    val handler = viewModel.handler(intent)
    when {
        intent.action == ShareAction.HIGHLIGHT && handler.isReady -> HighlightReviewContent(
            intent = intent,
            handler = viewModel.router.highlight,
            busy = busy,
            needsSwitch = intent.account != null && intent.account != active,
            onSwitchAccount = viewModel::switchAccount,
            onPublish = { passage, comment -> viewModel.publishHighlight(intent, passage, comment) },
            onDismiss = { viewModel.dismiss(intent) },
        )
        intent.action == ShareAction.PAY && handler.isReady -> PayReviewContent(
            intent = intent,
            needsSwitch = intent.account != null && intent.account != active,
            onSwitchAccount = viewModel::switchAccount,
            onDismiss = { viewModel.dismiss(intent) },
        )
        intent.action == ShareAction.DM && handler.isReady -> DMReviewContent(
            intent = intent,
            needsSwitch = intent.account != null && intent.account != active,
            onSwitchAccount = viewModel::switchAccount,
            onSent = { viewModel.dismiss(intent) },
            onDismiss = { viewModel.dismiss(intent) },
        )
        else -> {
            Text(label(intent.action), style = MaterialTheme.typography.titleMedium)
            Text(handler.notReadyMessage, color = SecondaryText)
            TextButton(onClick = { viewModel.dismiss(intent) }) { Text("Dismiss") }
        }
    }
}
