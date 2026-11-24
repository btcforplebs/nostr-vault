package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.nostrvault.relay.AccountReach
import com.nostrvault.relay.reachAccountNpub
import com.nostrvault.relay.reachFor
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.WindowBackground

/** Refresh Trust List options: stored value -> label (iOS RelayAccessSettingsView). */
internal val WOT_REFRESH_OPTIONS = listOf(
    "1h" to "Every hour", "12h" to "Every 12 hours", "24h" to "Every day", "168h" to "Every week",
)

/**
 * Who Can Reach You: who may write to your relay's inbox and chat (iOS
 * RelayAccessSettingsView). These used to be split between "Performance &
 * Limits" and "Global Web of Trust" in Advanced, although both answer the
 * same question. The old Rate Limits rows (events and connections per minute)
 * are gone: haven-go never read them, it uses its own fixed limits
 * (haven-go/limits.go).
 *
 * Follow Distance and Minimum Followers belong to the account you are on:
 * each account has its own (AccountReach.kt), and switching account shows
 * that account's values.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RelayAccessSettingsScreen(
    onBack: () -> Unit,
    viewModel: AdvancedSettingsViewModel = hiltViewModel(),
) {
    val config by viewModel.config.collectAsState()
    val isRestartingRelay by viewModel.isRestartingRelay.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Who Can Reach You") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                ),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            // The account you are on: each account has its own (AccountReach.kt).
            val reach = config.reachFor(config.reachAccountNpub)
            SectionLabel("Web of Trust")
            StepperRow(
                "Follow Distance", reach.depth, RelayAccessLimits.FOLLOW_DISTANCE, 1,
                SettingsHelp.RELAY_WOT_DEPTH, valueText = FollowDistanceWords.short(reach.depth),
            ) {
                viewModel.setWotDepth(it)
            }
            StepperRow("Minimum Followers", reach.minFollowers, AccountReach.MIN_FOLLOWERS, 1, SettingsHelp.RELAY_MIN_FOLLOWERS) {
                viewModel.setWotMinFollowers(it)
            }
            // Only said when there is more than one account to tell apart.
            if (config.allAccountNpubs().size > 1) {
                Caption("These two settings are for the account you are on. Each of your accounts has its own.")
            }
            PickerRow("Refresh Trust List", WOT_REFRESH_OPTIONS, config.wotRefreshInterval, SettingsHelp.RELAY_WOT_REFRESH) {
                viewModel.setWotRefresh(it)
            }

            Caption("Changes restart the relay automatically.")
            if (isRestartingRelay) Caption("Restarting relay…")

            Spacer(Modifier.height(32.dp))
        }
    }
}
