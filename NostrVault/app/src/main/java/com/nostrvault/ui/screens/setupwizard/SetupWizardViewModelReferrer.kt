package com.nostrvault.ui.screens

import com.nostrvault.relay.HavenBridge
import com.nostrvault.setup.ReferrerFollows
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

// ── Who told you about Nostr Vault? ──────────────────────────────

/** The hex key of the account being set up, once there is one. */
internal fun SetupWizardViewModel.ownerHexNow(): String? =
    configStore.config.value.ownerNpub.takeIf { it.startsWith("npub1") }?.let { HavenBridge.decodeNpub(it) }

fun SetupWizardViewModel.advanceFromReferrer() {
    _step.value = stepAfter(WizardStep.REFERRER)
}

/**
 * Only on New to Nostr (Logen 2026-11-05): a key made here can sign its first
 * follow list. Someone who already uses Nostr has their follows already, so
 * they are never asked.
 */
internal fun withReferrerStep(steps: List<WizardStep>, path: SetupPath): List<WizardStep> {
    if (path != SetupPath.NEW_TO_NOSTR || WizardStep.PROFILE !in steps) return steps
    return steps.toMutableList().apply { add(indexOf(WizardStep.PROFILE) + 1, WizardStep.REFERRER) }
}

@EntryPoint
@InstallIn(SingletonComponent::class)
interface ReferrerFollowEntryPoint {
    fun feedService(): com.nostrvault.service.FeedService
    fun nostrService(): com.nostrvault.service.NostrService
}

/**
 * Follows whoever the step picked, now that setup has stored the key and made
 * [accountHex] active. App scope: the wizard is gone by the time the list has
 * loaded and the follow is signed.
 */
internal fun SetupWizardViewModel.followReferrerPicks(accountHex: String) {
    val picks = ReferrerFollows.take()
    if (picks.isEmpty() || setupModeNow() == "browse") return
    val services = EntryPointAccessors.fromApplication(appContext, ReferrerFollowEntryPoint::class.java)
    val name = services.nostrService().profiles.value[picks.first()]?.bestName ?: "them"
    val label = if (picks.size == 1) name else "$name and ${picks.size - 1} more"
    CoroutineScope(SupervisorJob() + Dispatchers.Main).launch {
        services.feedService().followMany(picks, accountHex, label)
    }
}
