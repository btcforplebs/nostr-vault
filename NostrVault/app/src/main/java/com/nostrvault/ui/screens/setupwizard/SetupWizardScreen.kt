package com.nostrvault.ui.screens

import androidx.compose.animation.*
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.flow.first

/**
 * Setup wizard for first-run onboarding.
 * Full mode:   Welcome → Path → Account → Relays → Import → Media → Wallet → Complete
 * Browse mode: Welcome → Path → Account → Complete
 * Port of SetupWizardView.swift.
 */

// ══════════════════════════════════════════════════════════════════
// Screen
// ══════════════════════════════════════════════════════════════════

@Composable
fun SetupWizardScreen(
    onComplete: () -> Unit,
    viewModel: SetupWizardViewModel = hiltViewModel(),
) {
    val step by viewModel.step.collectAsState()
    val setupPath by viewModel.setupPath.collectAsState()
    val scrollState = rememberScrollState()

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(WizardBgPrimary),
    ) {
        // The front door fills the screen and pins its buttons, so it lives
        // outside the scrolling column, with no Back row, header or dots.
        if (step == WizardStep.WELCOME) {
            FrontDoor(onChoose = viewModel::choosePath)
            return@Box
        }

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(scrollState)
                .padding(horizontal = 24.dp)
                .statusBarsPadding()
                .navigationBarsPadding(),
        ) {
            Spacer(Modifier.height(32.dp))

            // Back button
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.Start,
            ) {
                IconButton(onClick = viewModel::goBack) {
                    Icon(
                        imageVector = NostrVaultIcons.Back,
                        contentDescription = "Back",
                        tint = SecondaryText,
                    )
                }
            }

            // App brand
            Text(
                text = "Nostr Vault",
                color = WizardAccent,
                fontSize = 32.sp,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = "Your personal relay",
                color = SecondaryText,
                fontSize = 16.sp,
            )

            // Step dots. The front door is not step 1 of N, so they count
            // from the screen after it.
            Spacer(Modifier.height(16.dp))
            StepDots(
                totalSteps = viewModel.activeSteps.size - 1,
                currentIndex = viewModel.currentStepIndex - 1,
            )

            Spacer(Modifier.height(32.dp))

            AnimatedContent(
                targetState = step,
                transitionSpec = {
                    (slideInHorizontally(Motion.panel()) { it } + fadeIn(Motion.panel())).togetherWith(
                        slideOutHorizontally(Motion.panel()) { -it } + fadeOut(Motion.panel())
                    )
                },
                label = "wizard_step",
            ) { currentStep ->
                when (currentStep) {
                    // Drawn outside this scrolling column; see FrontDoor above.
                    WizardStep.WELCOME -> Unit
                    WizardStep.RELAY_CHOICE -> RelayChoiceStep(viewModel)
                    WizardStep.NOSTR_INTRO -> NostrIntroStep(viewModel)
                    WizardStep.KEY_PASSWORD -> KeyPasswordStep(viewModel)
                    WizardStep.USE_NOSTR_KEY -> UseNostrKeyStep(viewModel)
                    WizardStep.RELAY_CHECK -> RelayCheckStep(viewModel)
                    WizardStep.IMPORT_TOUR -> ImportTourStep(viewModel, onComplete)
                    WizardStep.PROFILE -> ProfileStep(viewModel)
                    WizardStep.ACCOUNT -> AccountStep(viewModel)
                    WizardStep.RELAYS -> RelayStep(viewModel)
                    WizardStep.IMPORT_NOTES -> ImportNotesStep(viewModel)
                    WizardStep.MIRROR_MEDIA -> MirrorMediaStep(viewModel)
                    WizardStep.WALLET -> WalletSetupStep(viewModel)
                    WizardStep.NOTIFICATIONS -> NotificationsStep(viewModel)
                    WizardStep.COMPLETE -> CompleteStep(
                        setupPath = setupPath,
                        readOnly = viewModel.setupModeNow() == "browse",
                        onFinish = { viewModel.completeSetup(onComplete) },
                    )
                }
            }

            Spacer(Modifier.height(48.dp))
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Step Dots
// ══════════════════════════════════════════════════════════════════

@Composable
private fun StepDots(totalSteps: Int, currentIndex: Int) {
    Row(
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        for (i in 0 until totalSteps) {
            Box(
                modifier = Modifier
                    .size(if (i == currentIndex) 10.dp else 8.dp)
                    .clip(CircleShape)
                    .background(
                        when {
                            i < currentIndex -> WizardAccent.copy(alpha = 0.4f)
                            i == currentIndex -> WizardAccent
                            else -> WizardBorderSubtle
                        }
                    ),
            )
            if (i < totalSteps - 1) {
                Spacer(Modifier.width(8.dp))
            }
        }
    }
}
