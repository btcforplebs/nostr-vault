package com.nostrvault.service

import com.nostrvault.fips.MeshKeySigner
import com.nostrvault.relay.RelayConfiguration
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Publish for me (sync pick 1): the post path with a vault on the mesh ([VaultPublishHandoff]). The reader side
 * ([sendToRecipients]) goes at once; only the author's write relays and Blastr wait, up to
 * [VaultPublishHandoff.HOLD_MS], for the vault's answer. Then exactly one device blasts the note:
 * - the vault confirmed: this phone's relay gets a second-hand copy (stored, never blasted) and nothing else is sent;
 * - otherwise: what [postEventImpl] does without a vault (its relay blasts and retries, plus Blastr).
 */
internal fun NostrService.postThroughVault(
    event: NostrEvent,
    eventJson: String,
    vault: RelayConfiguration.MacMeshRelay,
    onBroadcastOutcome: ((BroadcastTally.Outcome) -> Unit)?,
) {
    scope.launch(Dispatchers.IO) {
        sendToRecipients(event)
        val decision = VaultPublishHandoff.handOff(vault.url, event.id, eventJson, MeshKeySigner.publish(vault.npub))
        // After the vault's answer: the mesh sender's second-hand copy to the same Mac would otherwise land first and
        // turn the publish into a "duplicate:" (HomeVaultSender sends with ?pulled=1).
        homeVault.offerEvent(event.id, event.pubkey, eventJson)
        if (decision == VaultHandoffDecision.VAULT_SENDS) {
            configStore.config.value.nostrURL?.let { VaultPublishHandoff.storeLocally(it, event.id, eventJson) }
            onBroadcastOutcome?.let { report -> withContext(Dispatchers.Main) { report(BroadcastTally.Outcome.ACCEPTED) } }
        } else {
            postToLocalRelay(eventJson)
            blastToAuthorRelays(event, onBroadcastOutcome)
        }
    }
}
