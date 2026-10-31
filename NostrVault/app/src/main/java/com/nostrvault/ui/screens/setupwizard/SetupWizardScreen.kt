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
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
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

        // As iOS: a "‹ Back" row, the step, then the dots pinned below it.
        // No brand header after the front door.
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding(),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 12.dp, end = 24.dp, top = 12.dp)
                    .height(36.dp),
            ) {
                TextButton(
                    onClick = viewModel::goBack,
                    contentPadding = PaddingValues(horizontal = 12.dp),
                ) {
                    Icon(
                        imageVector = NostrVaultIcons.Back,
                        contentDescription = null,
                        tint = WizardTextMuted,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text("Back", color = WizardTextMuted, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                }
            }

            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(scrollState)
                    .padding(horizontal = 24.dp),
            ) {
            Spacer(Modifier.height(16.dp))

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
                    WizardStep.REFERRER -> ReferrerStep(viewModel)
                    WizardStep.BACKUP_QUESTION -> BackupQuestionStep(viewModel, onComplete)
                    WizardStep.RELAY_CHECK -> RelayCheckStep(viewModel)
                    WizardStep.IMPORT_TOUR -> ImportTourStep(viewModel, onComplete)
                    WizardStep.PROFILE -> ProfileStep(viewModel)
                    WizardStep.STARTER_RELAYS -> StarterRelaysStep(viewModel)
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

            Spacer(Modifier.height(24.dp))
            }

            // The front door is not step 1 of N, so the dots count from the
            // screen after it.
            StepDots(
                totalSteps = viewModel.activeSteps.size - 1,
                currentIndex = viewModel.currentStepIndex - 1,
            )
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
        modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp),
    ) {
        for (i in 0 until totalSteps) {
            // iOS: every dot up to the current one is lit; the current one is
            // 10pt with a glow, the rest 6pt.
            val current = i == currentIndex
            Box(
                modifier = Modifier
                    .then(
                        if (current) Modifier.shadow(4.dp, CircleShape, ambientColor = WizardAccentGlow, spotColor = WizardAccentGlow)
                        else Modifier
                    )
                    .size(if (current) 10.dp else 6.dp)
                    .clip(CircleShape)
                    .background(if (i <= currentIndex) WizardAccent else WizardBorderSubtle),
            )
            if (i < totalSteps - 1) {
                Spacer(Modifier.width(8.dp))
            }
        }
    }
}
