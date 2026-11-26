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
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.net.URL

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

            // Notifications are asked once, by the app, now that setup is done
            // and the main screen shows (MainActivity, NotificationAsk). Push
            // stays off until that answer, and is on only if it's yes.
            configStore.update { it.copy(hasCompletedSetup = true, notificationAskPending = true) }

            // An existing account's DM inbox list (kind 10050) becomes this
            // device's. Setup doesn't publish one: the owner picks DM relays
            // and saves them in Settings > Relays (Logen 2026-10-31).
            runCatching { nostrService.adoptPublishedDMRelayList() }
            // An existing account's relay list (kind 10002) becomes this
            // device's read and write relays; the starters are only for none.
            runCatching { nostrService.adoptPublishedRelayList() }
            // An existing account's media servers (kind 10063) become upload servers.
            runCatching { nostrService.syncServerList() }

            // A new key's relay list goes out before its first follows: a
            // list saved without it (the guide's hashtags) has no relays of
            // its own to check, and was refused "no relay list" (2026-11-26).
            if (_setupPath.value == SetupPath.NEW_TO_NOSTR && ownerIsGeneratedKey()) publishNewAccount()

            // Who told you about Nostr Vault: follow them, and whoever of
            // their follows stayed ticked, now that this key is active.
            ownerHexNow()?.let { followReferrerPicks(it) }

            onComplete()
        }
    }

    /**
     * Publishes what a brand-new account needs to exist for other people:
     * the recommended relay list ([StarterRelays]) and
     * a profile. Its follow list starts with its first
     * follow, in the Fill your feed guide. Same as iOS. Runs once setup has
     * stored the key, because each event is signed by it, and only on New to
     * Nostr, whose key was generated in this run and so has none of these
     * events anywhere yet. The relay list is posted before this returns, so
     * it goes out ahead of the referrer follows; the profile outlives the
     * wizard (app scope), because its photo upload can take 30 s.
     */
    internal suspend fun SetupWizardViewModel.publishNewAccount() {
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

        // The recommended list; Settings > Relays changes it later.
        val relayTags = StarterRelays.tags(configStore.config.value.activeFeedRelays)
        if (relayTags.isNotEmpty() && stillGenerated()) withContext(Dispatchers.IO) {
            withTimeoutOrNull(RELAY_LIST_SIGN_TIMEOUT_MS) {
                runCatching { nostrService.signEventAsync(kind = 10002, content = "", tags = relayTags) }.getOrNull()
            }?.takeIf { signedByNewKey(it.pubkey, generated) }?.let { nostrService.postEvent(it) }
        }

        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            if (!stillGenerated()) return@launch
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

/** A key setup just made signs locally; this only stops a stuck signer holding setup open. */
internal const val RELAY_LIST_SIGN_TIMEOUT_MS = 10_000L

/** A new account's relay list or profile goes out only if the new key signed it. */
internal fun signedByNewKey(signedPubkey: String?, generatedHex: String): Boolean =
    signedPubkey != null && signedPubkey.equals(generatedHex, ignoreCase = true)
