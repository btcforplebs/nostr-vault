package com.nostrvault.service

import com.nostrvault.fips.MeshKeySigner
import com.nostrvault.relay.RelayConfiguration
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Publish for me (sync pick 1): the post path for a regular note with a vault on the mesh ([VaultPublishHandoff]) and
 * the author's own write relays known ([plan], [VaultPublishHandoff.authorPlan]). The reader side
 * ([sendToRecipients]) and the author's own relays ([PublishTargets.Plan.confirmed], which decide "Posted") go at
 * once, whoever blasts. Only the fan-out ([PublishTargets.Plan.alsoSend]) and this phone's relay wait, up to
 * [VaultPublishHandoff.HOLD_MS], for the vault's answer. Then exactly one device fans the note out:
 * - the vault confirmed: this phone's relay gets a second-hand copy (stored, never blasted), no fan-out from here;
 * - otherwise: this phone's relay blasts and retries, plus the fan-out, as without a vault.
 */
internal fun NostrService.postThroughVault(
    event: NostrEvent,
    eventJson: String,
    vault: RelayConfiguration.MacMeshRelay,
    plan: PublishTargets.Plan,
    onBroadcastOutcome: ((BroadcastTally.Outcome) -> Unit)?,
) {
    // "Posted" comes from the author's own relays, never from the vault's OK (Tron review of PR 1970, M1).
    sendConfirmed(event, plan.confirmed, onBroadcastOutcome)
    scope.launch(Dispatchers.IO) {
        sendToRecipients(event)
        val decision = VaultPublishHandoff.handOff(vault.url, event.id, eventJson, MeshKeySigner.publish(vault.npub))
        // After the vault's answer: the mesh sender's second-hand copy to the same Mac would otherwise land first and
        // turn the publish into a "duplicate:" (HomeVaultSender sends with ?pulled=1).
        homeVault.offerEvent(event.id, event.pubkey, eventJson)
        if (VaultPublishHandoff.localRelayBlasts(decision)) {
            postToLocalRelay(eventJson)
        } else {
            configStore.config.value.nostrURL?.let { VaultPublishHandoff.storeLocally(it, event.id, eventJson) }
        }
        VaultPublishHandoff.heldSends(decision, plan).forEach { fireAndForgetPublish(event, it) }
    }
}
