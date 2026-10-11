package com.nostrvault.ui.screens.dashboard

import android.util.Log
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import kotlinx.coroutines.launch
import androidx.compose.foundation.layout.offset
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.model.*
import com.nostrvault.service.NostrEvent
import com.nostrvault.ui.theme.*
import com.nostrvault.util.RelayGiven
import com.nostrvault.util.WalletTransaction
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.TAG
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.MAX_ZAP_RECEIPT_CACHE
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.WALLET_GIVEN_PAGES
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.Companion.WALLET_GIVEN_PAGE_SIZE
import com.nostrvault.ui.screens.dashboard.DashboardViewModel.WalletGiven

    internal fun DashboardViewModel.fetchMissingZappedNotes() {
        viewModelScope.launch(Dispatchers.Default) {
            val events = allEventsMutex.withLock { allEvents.toList() }
            val zapReceipts = events.filter { it.kind == 9735 }

            val targetNoteIds = mutableSetOf<String>()
            for (receipt in zapReceipts) {
                val cached = zapReceiptCache[receipt.id]
                if (cached != null) {
                    cached.targetNoteId?.let { targetNoteIds.add(it) }
                } else {
                    val targetId = receipt.tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1)
                    if (targetId != null) targetNoteIds.add(targetId)
                }
            }

            // Posts this app zapped from this phone, for Given (iOS #296).
            targetNoteIds.addAll(feedService.zappedEventIds.value.keys.filter(RelayGiven::isEventId))

            val existingIds = events.map { it.id }.toSet()
            val missingIds = targetNoteIds.subtract(existingIds).subtract(requestedMissingZapNoteIds)
            if (missingIds.isEmpty()) return@launch

            for (id in missingIds) requestedMissingZapNoteIds.add(id)
            Log.d(TAG, "Fetching ${missingIds.size} missing zapped notes")

            val relayUrls = buildExternalRelayUrls()
            nostrService.fetchNotesByIds(missingIds.toList(), relayUrls)
        }
    }

    internal fun DashboardViewModel.fetchMoreZapReceipts() {
        fetchGivenZapsFromWallet()
        if (hasFetchedZapReceipts) return
        hasFetchedZapReceipts = true

        val localUrl = configStore.config.value.nostrURL ?: return
        val urls = listOfNotNull(localUrl, configStore.config.value.localInboxURL).distinct()
        Log.d(TAG, "Fetching extended zap receipts history")
        nostrService.fetchZapReceipts(urls)

        // Your relay only holds receipts that tag you with `p`, i.e. zaps you
        // received. The receipt for a zap you sent is published to the relays
        // of the person you zapped and tags you with `P`, so "Given" stayed
        // empty. Ask the feed relays for those.
        val owner = nostrService.activeHexPubkey
        if (owner.isNotEmpty()) {
            // Your published inbox too: zaps sent from here ask for receipts there.
            val externalUrls = (buildExternalRelayUrls() + nostrService.relayLists.value[owner].orEmpty())
                .filter { it != localUrl }
                .distinctBy { it.lowercase() }
            nostrService.fetchZapReceipts(externalUrls, limit = 500, tagFilter = mapOf("#P" to listOf(owner)))
        }
    }

    /** Lets a refresh or account switch ask again for posts still missing. */
    internal fun DashboardViewModel.forgetGivenLookups() {
        requestedMissingIds.clear()
        requestedMissingZapNoteIds.clear()
        hasFetchedZapReceipts = false
    }

    /**
     * Zaps > Given from the wallet: the zaps the connected NWC wallet paid,
     * matched to their posts the same way the wallet's own history is. Read
     * once per account and wallet; a pull-to-refresh does not redo it.
     */
    private fun DashboardViewModel.fetchGivenZapsFromWallet() {
        val owner = nostrService.activeHexPubkey
        val nwcURI = configStore.config.value.nwcURI
        if (owner.isEmpty() || nwcURI.isNullOrBlank() || _walletGivenLoading.value) return
        val key = "$owner|$nwcURI"
        if (walletGivenKey == key) return
        walletGivenKey = key
        walletGiven = WalletGiven()
        _walletGivenLoading.value = true
        val gen = walletGivenGen
        fun stillCurrent() = walletGivenGen == gen && walletGivenKey == key

        viewModelScope.launch(Dispatchers.IO) {
            try {
                val sent = mutableListOf<WalletTransaction>()
                for (page in 0 until WALLET_GIVEN_PAGES) {
                    val txs = try {
                        nwcService.listTransactions(limit = WALLET_GIVEN_PAGE_SIZE, offset = page * WALLET_GIVEN_PAGE_SIZE)
                    } catch (e: Exception) {
                        // Unsupported or unreachable: try again on the next visit.
                        Log.w(TAG, "Wallet history for Given failed: ${e.message}")
                        if (page == 0 && stillCurrent()) walletGivenKey = null
                        break
                    }
                    sent += txs.filter {
                        it.direction == WalletTransaction.Direction.OUTGOING &&
                            it.state == WalletTransaction.State.SETTLED
                    }
                    if (txs.size < WALLET_GIVEN_PAGE_SIZE) break
                }
                if (!stillCurrent() || sent.isEmpty()) return@launch

                val found = zapHistoryService.lookup(sent, owner)
                if (!stillCurrent()) return@launch
                val notes = mutableListOf<FeedNote>()
                val amounts = HashMap<String, Long>()
                val times = HashMap<String, Long>()
                for (tx in sent.sortedByDescending { it.createdAt }) {
                    val postId = found.details[tx.id]?.postId ?: continue
                    val note = found.posts[postId] ?: continue
                    if (postId !in amounts) {
                        notes.add(note)
                        times[postId] = tx.createdAt
                    }
                    amounts[postId] = (amounts[postId] ?: 0L) + tx.amountSats
                }
                walletGiven = WalletGiven(notes, amounts, times)
            } finally {
                if (walletGivenGen == gen) {
                    _walletGivenLoading.value = false
                    scheduleUpdateDisplayData()
                }
            }
        }
    }

    internal fun DashboardViewModel.parseZapReceipt(event: NostrEvent): ParsedZapReceipt? {
        zapReceiptCache[event.id]?.let { return it }

        val descJson = event.tags.firstOrNull { it.size >= 2 && it[0] == "description" }?.get(1) ?: return null
        try {
            val zapReq = json.parseToJsonElement(descJson).jsonObject
            val senderPubkey = zapReq["pubkey"]?.jsonPrimitive?.contentOrNull ?: return null
            val reqTags = zapReq["tags"]?.jsonArray
            // The note comes from the signed request, not the receipt: a forged
            // receipt can wrap your real request and point it at another note.
            val requestTargetId = reqTags?.firstNotNullOfOrNull { tag ->
                val tagArr = tag as? JsonArray ?: return@firstNotNullOfOrNull null
                if (tagArr.size >= 2 && (tagArr[0] as? JsonPrimitive)?.contentOrNull == "e") (tagArr[1] as? JsonPrimitive)?.contentOrNull else null
            }
            val targetId = requestTargetId ?: event.tags.firstOrNull { it.size >= 2 && it[0] == "e" }?.get(1)

            // The request's `amount` tag is optional (NIP-57); the paid invoice is not.
            val amountSats = com.nostrvault.util.ZapAmount.sats(event.tags)

            val parsed = ParsedZapReceipt(senderPubkey, targetId, amountSats, com.nostrvault.relay.HavenBridge.verifyEvent(descJson))
            zapReceiptCache[event.id] = parsed
            if (zapReceiptCache.size > MAX_ZAP_RECEIPT_CACHE) {
                val toRemove = zapReceiptCache.keys.take(zapReceiptCache.size - MAX_ZAP_RECEIPT_CACHE)
                toRemove.forEach { zapReceiptCache.remove(it) }
            }
            return parsed
        } catch (_: Exception) {
            return null
        }
    }
