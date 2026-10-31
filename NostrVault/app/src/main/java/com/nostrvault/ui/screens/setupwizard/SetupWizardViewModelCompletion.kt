package com.nostrvault.ui.screens

import androidx.compose.animation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.viewModelScope
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.RelayConfiguration
import com.nostrvault.tutorials.TutorialCenter
import com.nostrvault.tutorials.TutorialID
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.net.URL

    /** [enable] is "Enable Notifications" (the caller has asked Android for
     *  the permission); false is "Not now". Either way setup won't ask again. */
    fun SetupWizardViewModel.finishNotifications(enable: Boolean, dms: Boolean, zaps: Boolean, mentions: Boolean) {
        configStore.update {
            if (enable) {
                it.copy(
                    notificationPermissionAsked = true,
                    pushNotifyDMs = dms,
                    pushNotifyZaps = zaps,
                    pushNotifyMentions = mentions,
                )
            } else {
                it.copy(notificationPermissionAsked = true)
            }
        }
        _step.value = stepAfter(WizardStep.NOTIFICATIONS)
    }

    // ── Complete ─────────────────────────────────────────────────

    fun SetupWizardViewModel.completeSetup(onComplete: () -> Unit) {
        viewModelScope.launch {
            // Resolve active account hex pubkey (matches iOS refreshActiveAccountHex).
            // Done before hasCompletedSetup flips: MainActivity starts the DM
            // listeners on that flip, and they subscribe for the active account.
            val npub = configStore.config.value.ownerNpub
            if (npub.startsWith("npub1")) {
                try {
                    val hex = HavenBridge.decodeNpub(npub)
                    if (!hex.isNullOrEmpty()) {
                        configStore.setActiveAccount(hex)
                        // A key made here has no follow list anywhere yet. Only
                        // that key: never an account someone pasted in.
                        if (_setupPath.value == SetupPath.NEW_TO_NOSTR && hex == generatedPkHex) {
                            com.nostrvault.service.FreshAccountKeys.mark(appContext, hex)
                            // Straight into Fill your feed: this key follows
                            // nobody yet, so there is nothing to wait for.
                            com.nostrvault.tutorials.TutorialCenter.startIfEligible(
                                com.nostrvault.tutorials.TutorialID.FILL_YOUR_VAULT, hex,
                            )
                        }
                    }
                } catch (_: Exception) {}
            }

            // New accounts start with notifications on (DMs, replies, mentions
            // and zaps per PushPrefs' defaults) — otherwise a
            // first DM arrives silently. Set here rather than as the config
            // default so existing installs keep whatever they had.
            configStore.update { it.copy(hasCompletedSetup = true, enablePushNotifications = true) }

            // Who told you about Nostr Vault: follow them, and whoever of
            // their follows stayed ticked, now that this key is active.
            ownerHexNow()?.let { followReferrerPicks(it) }

            // An existing account's DM inbox list (kind 10050) becomes this
            // device's. Setup doesn't publish one: the owner picks DM relays
            // and saves them in Settings > Relays (Logen 2026-10-31).
            runCatching { nostrService.adoptPublishedDMRelayList() }
            // An existing account's media servers (kind 10063) become upload servers.
            runCatching { nostrService.syncServerList() }

            if (_setupPath.value == SetupPath.NEW_TO_NOSTR && ownerIsGeneratedKey()) publishNewAccount()

            onComplete()
        }
    }

    /**
     * Publishes what a brand-new account needs to exist for other people:
     * a relay list (only the starter list the person chose Use on; Skip
     * publishes none) and a profile. Its follow list starts with its first
     * follow, in the Fill your feed guide. Same as iOS. Runs once setup has
     * stored the key, because each event is signed by it, and only on New to
     * Nostr, whose key was generated in this run and so has none of these
     * events anywhere yet. Outlives the wizard (app scope).
     */
    internal fun SetupWizardViewModel.publishNewAccount() {
        val name = _profileName.value.trim()
        val photo = _profilePhotoJpeg.value
        val generated = generatedPkHex ?: return
        // Each event is signed by whichever account is active, so check it
        // is still the generated key right before signing, and drop anything
        // signed by another key: the photo upload can take 30 s, and a kind 0
        // or 10002 signed by another account would replace that account's own
        // (iOS 5cd4b5e9).
        fun stillGenerated() = nostrService.activeHexPubkey == generated &&
            HavenBridge.decodeNpub(configStore.config.value.ownerNpub) == generated

        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            if (!stillGenerated()) return@launch
            val relayTags = StarterRelays.tags(_starterRelays.value, _publishStarterRelays.value)
            if (relayTags.isNotEmpty()) {
                runCatching { nostrService.signEventAsync(kind = 10002, content = "", tags = relayTags) }
                    .getOrNull()?.takeIf { signedByNewKey(it.pubkey, generated) }?.let { nostrService.postEvent(it) }
            }

            val profile = JSONObject()
            if (name.isNotEmpty()) {
                profile.put("name", name)
                profile.put("display_name", name)
            }
            if (photo != null) {
                // Hosted URL only: a picture only this phone can serve is left off.
                val sha = java.security.MessageDigest.getInstance("SHA-256").digest(photo)
                    .joinToString("") { "%02x".format(it) }
                runCatching { blossomService.uploadAndMirror(photo, sha, "image/jpeg") }
                    .getOrNull()?.let { profile.put("picture", it) }
            }
            if (profile.length() == 0 || !stillGenerated()) return@launch
            runCatching { nostrService.signEventAsync(kind = 0, content = profile.toString(), tags = emptyList()) }
                .getOrNull()?.takeIf { signedByNewKey(it.pubkey, generated) }?.let { nostrService.postEvent(it) }
        }
    }

/** A new account's relay list or profile goes out only if the new key signed it. */
internal fun signedByNewKey(signedPubkey: String?, generatedHex: String): Boolean =
    signedPubkey != null && signedPubkey.equals(generatedHex, ignoreCase = true)
