package com.nostrvault.service

import android.util.Log
import com.nostrvault.BuildConfig
import com.nostrvault.data.remote.WebSocketClient
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.JsonObject
import com.nostrvault.service.DMService.Companion.INJECTION_CONNECT_TIMEOUT_MS
import com.nostrvault.service.DMService.Companion.INJECTION_INTERVAL_MS
import com.nostrvault.service.DMService.Companion.MAX_INJECTED_DM_IDS
import com.nostrvault.service.DMService.Companion.MAX_INJECTION_QUEUE
import com.nostrvault.service.DMService.Companion.TAG

/**
 * Writes DMs fetched from OUTSIDE relays back into this device's own relay, so
 * they persist in the relay DB and reach the account's other devices through
 * the relay's sync — the iOS behaviour (DMService+LocalInjection.swift).
 *
 * Android declared the state for this (chatInjectionClient, injectedDmIds) and
 * never wrote a byte: externally-fetched DMs lived only in the JSON
 * conversation cache, so clearing the cache or reinstalling lost them and they
 * never showed up on any other device.
 *
 * Two things shape how it writes:
 *
 * 1. The write goes over the LIVE /chat and /inbox sockets, not a temporary one
 *    like iOS uses. A gift wrap's author is a throwaway key that is in nobody's
 *    web of trust, so haven-go's MustBeInWotToPost falls through to the
 *    authenticated user — an unauthenticated socket is answered
 *    "auth-required". The live sockets have already done NIP-42 AUTH, and under
 *    Amber or a bunker a fresh AUTH is a signer round trip (or prompt).
 * 2. Writes are PACED. The chat relay's per-IP event limiter allows about 50
 *    events a minute for an author that isn't whitelisted, and the one-time
 *    sent-copy catch-up can fetch up to a thousand wraps. Firing them at once
 *    would have most of them rejected as rate-limited, which is exactly the
 *    silent data loss this fix exists to end.
 */
internal fun DMService.injectExternalDmIntoLocalRelay(eventObj: JsonObject, eventId: String, kind: Int) {
    // The caller has already verified the signature. Never inject an unverified
    // event: this writes into the user's own relay, which their other devices
    // treat as authoritative.
    if (!injectedDmIds.add(eventId)) return
    if (injectedDmIds.size > MAX_INJECTED_DM_IDS) injectedDmIds.clear()

    if (injectionQueue.size >= MAX_INJECTION_QUEUE) {
        // Un-claim it so a later fetch round can try again rather than leaving
        // the id marked as injected when nothing was written.
        injectedDmIds.remove(eventId)
        return
    }
    injectionQueue.add(
        DMService.PendingInjection(
            kind = kind,
            frame = "[\"EVENT\",$eventObj]",
            eventId = eventId,
            generation = switchGeneration,
        ),
    )
    drainInjections()
}

/** Starts the single paced drainer, if it isn't already running. */
private fun DMService.drainInjections() {
    if (!injectionDraining.compareAndSet(false, true)) return
    scope.launch {
        try {
            while (true) {
                val item = injectionQueue.poll() ?: break
                if (item.generation != switchGeneration) continue
                if (!sendInjection(item)) {
                    // The socket never came up. Give the id back and stop; the
                    // next fetch round re-queues whatever is still missing.
                    injectedDmIds.remove(item.eventId)
                    break
                }
                delay(INJECTION_INTERVAL_MS)
            }
        } finally {
            injectionDraining.set(false)
        }
        // Something queued between the empty poll and the flag clearing.
        if (injectionQueue.isNotEmpty()) drainInjections()
    }
}

/** @return false when the target socket never reached CONNECTED. */
private suspend fun DMService.sendInjection(item: DMService.PendingInjection): Boolean {
    val client = (if (item.kind == 1059) inboxClient else nip04Client) ?: return false
    if (client.connectionState.value != WebSocketClient.ConnectionState.CONNECTED) {
        withTimeoutOrNull(INJECTION_CONNECT_TIMEOUT_MS) {
            client.connectionState.first { it == WebSocketClient.ConnectionState.CONNECTED }
        } ?: return false
    }
    if (item.generation != switchGeneration) return true
    val sent = client.send(item.frame)
    if (!sent) {
        Log.w(TAG, "Could not inject DM ${item.eventId.take(8)} into the local relay")
        return false
    }
    if (BuildConfig.DEBUG) Log.d(TAG, "DBG: injected DM ${item.eventId.take(8)} (kind ${item.kind})")
    return true
}
