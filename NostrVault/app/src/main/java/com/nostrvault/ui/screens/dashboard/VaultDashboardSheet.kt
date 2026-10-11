package com.nostrvault.ui.screens.dashboard

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import com.nostrvault.tutorials.LocalTutorialLayer
import com.nostrvault.tutorials.TutorialCenter
import com.nostrvault.tutorials.TutorialID
import com.nostrvault.tutorials.TutorialStage
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.*
import com.nostrvault.ui.navigation.Screen
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import com.nostrvault.ui.screens.BlossomDashboardSections

/** The relay dashboard sheet's [TutorialStage]. */
private const val RELAY_DASHBOARD_TUTORIAL_LAYER = "relayDashboard"

// ═══════════════════════════════════════════════════════════════════
// Vault Dashboard sheet
// ═══════════════════════════════════════════════════════════════════

/** The Vault Dashboard sheet's pages: the dashboard, and the two Advanced pages inside it. */
private enum class VaultDashboardPage { MAIN, RELAY_DETAILS, MEDIA_DETAILS }

/**
 * The Vault Dashboard (v2, iOS `VaultDashboardView`): one page that says
 * whether your vault is OK. The Vault tab presents it over either half: the
 * pill's last entry, the floating Vault button and the folded bar's corner
 * button all open it. The old relay dashboard and Blossom's sections live on
 * under Advanced (Relay details, Media server details).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun VaultDashboardSheet(
    viewModel: DashboardViewModel,
    logStore: com.nostrvault.relay.LogStore,
    onNavigate: (Screen) -> Unit,
    onDismiss: () -> Unit,
) {
    val tutorialRevision by TutorialCenter.revision.collectAsState()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var page by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(VaultDashboardPage.MAIN) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = WindowBackground,
        dragHandle = {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.padding(top = 12.dp, bottom = 4.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(width = 36.dp, height = 4.dp)
                        .background(
                            SecondaryText.copy(alpha = 0.4f),
                            RoundedCornerShape(2.dp),
                        ),
                )
            }
        },
    ) {
        // The Vault in Your Pocket tutorial starts the first time the dashboard
        // opens. The sheet is its own window, so it draws its own cards.
        LaunchedEffect(tutorialRevision) {
            TutorialCenter.startIfEligible(TutorialID.POCKET_RELAY, viewModel.nostrService.activeHexPubkey)
        }
        // Back from an Advanced page returns to the dashboard, not out of the sheet.
        androidx.activity.compose.BackHandler(enabled = page != VaultDashboardPage.MAIN) {
            page = VaultDashboardPage.MAIN
        }
        CompositionLocalProvider(LocalTutorialLayer provides RELAY_DASHBOARD_TUTORIAL_LAYER) {
        Box {
        when (page) {
            VaultDashboardPage.MAIN -> com.nostrvault.ui.screens.dashboard.VaultDashboardContent(
                vaultViewModel = viewModel,
                logStore = logStore,
                onOpenScreen = { screen ->
                    onDismiss()
                    onNavigate(screen)
                },
                onOpenMode = { mode ->
                    onDismiss()
                    viewModel.selectMode(mode)
                },
                onOpenRelayDetails = { page = VaultDashboardPage.RELAY_DETAILS },
                onOpenMediaDetails = { page = VaultDashboardPage.MEDIA_DETAILS },
            )
            VaultDashboardPage.RELAY_DETAILS -> RelayDetailsPage(
                viewModel = viewModel,
                logStore = logStore,
                onNavigate = onNavigate,
                onDismiss = onDismiss,
                onBack = { page = VaultDashboardPage.MAIN },
            )
            VaultDashboardPage.MEDIA_DETAILS -> Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp)
                    .padding(bottom = 32.dp),
            ) {
                SheetPageHeader(title = "Media server details", onBack = { page = VaultDashboardPage.MAIN })
                BlossomDashboardSections(onOpenSettings = {
                    onDismiss()
                    onNavigate(Screen.BlossomSettings)
                })
            }
        }
        TutorialStage(
            account = { viewModel.nostrService.activeHexPubkey },
            modifier = Modifier.matchParentSize(),
            layer = RELAY_DASHBOARD_TUTORIAL_LAYER,
        )
        }
        }
    }
}

/** An Advanced page's title row, with the way back to the dashboard. */
@Composable
private fun SheetPageHeader(title: String, onBack: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 16.dp),
    ) {
        IconButton(onClick = onBack, modifier = Modifier.size(32.dp)) {
            Icon(NostrVaultIcons.Back, "Back to Vault Dashboard", tint = LocalNostrVaultColors.current.primary, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.width(8.dp))
        Text(text = title, color = PrimaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold)
    }
}
