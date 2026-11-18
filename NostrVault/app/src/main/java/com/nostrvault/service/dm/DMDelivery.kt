package com.nostrvault.service

import kotlinx.coroutines.*
import java.util.concurrent.atomic.AtomicInteger

/*
 * Whether your message got anywhere (Messages check A2; web net/dms.js sendMessage).
 *
 * The bubble says "Sending…" until one of their relays takes it, then it is an
 * ordinary sent message. When every one refuses or times out it says "Not sent"
 * with Try again and Remove. Before this, a refusal was only logged and the
 * bubble looked delivered.
 *
 * Their copy goes first. Your own copy (your DM inbox relays, the vault) follows
 * only once a relay of theirs took it: a refused message must never come back
 * from your own relay looking sent.
 */

/**
 * Publishes [eventJson] to every one of [urls] at once. True as soon as one takes
 * it, false once none did. The rest carry on behind it: more copies out there.
 * [senderHex] answers NIP-42 AUTH; null publishes without it (NIP-04).
 */
internal suspend fun DMService.firstAccepted(eventJson: String, urls: List<String>, senderHex: String?): Boolean {
    if (urls.isEmpty()) return false
    val delivered = CompletableDeferred<Boolean>()
    val left = AtomicInteger(urls.size)
    for (url in urls) {
        scope.launch {
            var taken = false
            try {
                taken = publishDM(eventJson, url, senderHex) == "accepted"
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                taken = false
            } finally {
                // Counted however it ended (a cancel too), so the bubble never waits forever.
                if (taken) delivered.complete(true)
                else if (left.decrementAndGet() == 0) delivered.complete(false)
            }
        }
    }
    return delivered.await()
}

/** The bubble's words for a send none of [relays] took. */
internal fun notDeliveredReason(relays: Int): String =
    "None of their $relays relay${if (relays == 1) "" else "s"} took it."

/**
 * Sets your message [id]'s [state] (null = sent) in the inbox that is still
 * [cacheKey]'s. After an account switch the old inbox is on disk; the bubble
 * there is settled when it loads ([withInterruptedSendsFailed]).
 */
internal suspend fun DMService.setSendState(
    cacheKey: String?,
    counterparty: String,
    id: String,
    state: DMSendState?,
    failure: String? = null,
) = withContext(Dispatchers.Main.immediate) {
    if (loadedCacheKey != cacheKey) return@withContext
    val current = _conversations.value
    val index = current.indexOfFirst { it.id == counterparty }
    if (index < 0) return@withContext
    val conv = current[index]
    val at = conv.messages.indexOfFirst { it.id == id }
    if (at < 0) return@withContext
    val messages = conv.messages.toMutableList()
    val m = messages[at]
    messages[at] = m.copy(
        sendState = state,
        failure = if (state == DMSendState.FAILED) failure else null,
        resendText = if (state == null) null else m.resendText,
    )
    _conversations.value = current.toMutableList().also { it[index] = conv.copy(messages = messages) }
    saveCachedConversations()
}

/** NIP-17: their wrap to their relays, then (once one took it) your own copy and the vault's. */
internal suspend fun DMService.deliverNIP17(
    cacheKey: String?,
    counterparty: String,
    id: String,
    recipientEvent: String,
    selfEvent: String,
    recipientRelays: List<String>,
    ownHex: String,
) {
    if (!firstAccepted(recipientEvent, recipientRelays, ownHex)) {
        sendRetries[id] = { deliverNIP17(cacheKey, counterparty, id, recipientEvent, selfEvent, recipientRelays, ownHex) }
        setSendState(cacheKey, counterparty, id, DMSendState.FAILED, notDeliveredReason(recipientRelays.size))
        return
    }
    sendRetries.remove(id)
    setSendState(cacheKey, counterparty, id, null)
    if (configStore.config.value.localRelayURL("chat") != null) {
        inboxClient?.send("[\"EVENT\",$recipientEvent]")
        inboxClient?.send("[\"EVENT\",$selfEvent]")
    }
    for (relayUrl in ownDMInboxRelays(ownHex)) scope.launch { publishDM(selfEvent, relayUrl, ownHex) }
}

/** NIP-04: the one event to their relays, then (once one took it) the vault and your other relays. */
internal suspend fun DMService.deliverNIP04(
    cacheKey: String?,
    counterparty: String,
    id: String,
    eventJson: String,
    recipientRelays: List<String>,
    ownRelays: List<String>,
) {
    if (!firstAccepted(eventJson, recipientRelays, null)) {
        sendRetries[id] = { deliverNIP04(cacheKey, counterparty, id, eventJson, recipientRelays, ownRelays) }
        setSendState(cacheKey, counterparty, id, DMSendState.FAILED, notDeliveredReason(recipientRelays.size))
        return
    }
    sendRetries.remove(id)
    setSendState(cacheKey, counterparty, id, null)
    if (configStore.config.value.localInboxURL != null) nip04Client?.send("[\"EVENT\",$eventJson]")
    // A kind 4 has no self-copy: your other devices find it on your own relays.
    for (relayUrl in ownRelays) if (relayUrl !in recipientRelays) scope.launch { publishDM(eventJson, relayUrl, null) }
}

/**
 * Try again on a "Not sent" bubble: the same signed message again when it is
 * still here, or (after a restart) its words as a new message. A locked photo
 * after a restart can only be removed.
 */
fun DMService.retrySend(counterparty: String, id: String) {
    scope.launch {
        val again = sendRetries.remove(id)
        if (again != null) {
            setSendState(loadedCacheKey, counterparty, id, DMSendState.SENDING)
            again()
            return@launch
        }
        val unsent = _conversations.value.firstOrNull { it.id == counterparty }
            ?.messages?.firstOrNull { it.id == id } ?: return@launch
        // Only a bubble that says Not sent: a second tap while this one is going finds it Sending (Tron #2230).
        if (unsent.sendState != DMSendState.FAILED) return@launch
        val words = unsent.resendText ?: return@launch
        val key = loadedCacheKey
        setSendState(key, counterparty, id, DMSendState.SENDING)
        try {
            // As it was sent: a NIP-04 message stays NIP-04. The old bubble goes only once the new
            // one is built; if it can't be (no key, signer refused), the words stay, Not sent.
            sendDM(words, counterparty, useNIP04 = unsent.isNIP04)
            withContext(Dispatchers.Main.immediate) {
                if (loadedCacheKey == key) removeMessageFromConversation(counterparty, id)
            }
        } catch (e: CancellationException) {
            setSendState(key, counterparty, id, DMSendState.FAILED, unsent.failure)
            throw e
        } catch (e: Exception) {
            setSendState(key, counterparty, id, DMSendState.FAILED, e.message ?: unsent.failure)
        }
    }
}

/** Whether Try again can do anything for [message]. */
fun DMService.canRetry(message: DMMessage): Boolean =
    message.sendState == DMSendState.FAILED && (sendRetries.containsKey(message.id) || message.resendText != null)

/** Remove on a "Not sent" bubble. */
fun DMService.removeUnsent(counterparty: String, id: String) {
    sendRetries.remove(id)
    removeMessageFromConversation(counterparty, id)
}

/**
 * A message still "Sending…" in a saved inbox was cut off (the app closed, or
 * the account changed) before any relay answered. It loads as "Not sent", so it
 * is never left spinning.
 */
internal fun List<DMConversation>.withInterruptedSendsFailed(): List<DMConversation> {
    if (none { c -> c.messages.any { it.sendState == DMSendState.SENDING } }) return this
    return map { c ->
        if (c.messages.none { it.sendState == DMSendState.SENDING }) c
        else c.copy(
            messages = c.messages.map {
                if (it.sendState == DMSendState.SENDING) {
                    it.copy(sendState = DMSendState.FAILED, failure = INTERRUPTED_SEND)
                } else it
            },
        )
    }
}

internal const val INTERRUPTED_SEND = "Sending was cut off before a relay answered. It may not have gone out."
