package com.nostrvault.service

import android.content.Context
import android.util.Base64
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.GatedArticle
import com.nostrvault.data.model.NIP10Thread
import com.nostrvault.di.ApplicationScope
import com.nostrvault.relay.HavenBridge
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Opens and unlocks gated ("zap N sats to unlock") articles. iOS
 * GatedArticleService (before #812).
 *
 * Any gated article opens from a key this reader already has on the device.
 * Only a Fanfares article ([GatedArticle.isFanfares], owner decision
 * 2026-10-20) is unlocked here: a NIP-98 key request (kind 27235, a request
 * header, never published) and an in-app zap of each share of the price.
 * Every other gated article stays locked: this service never signs, asks or
 * pays for one, whatever the UI calls.
 *
 * The key server is the only judge of whether a zap counted, so this never
 * decides "paid" itself: it asks, and a 402 means not yet.
 */
@Singleton
class GatedArticleService @Inject constructor(
    @ApplicationContext context: Context,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val zapSendService: ZapSendService,
    @ApplicationScope private val appScope: CoroutineScope,
) {
    sealed class UnlockError(message: String) : Exception(message) {
        object NotSignedIn : UnlockError("Sign in to unlock this article.")
        object SignFailed : UnlockError("Your signer didn't sign the unlock request.")
        object NotPaid : UnlockError("The author hasn't seen your zap yet.")
        object NoLightningAddress : UnlockError("The author has no lightning address to zap.")
        /** Not a Fanfares article: Nostr Vault does not unlock it. */
        object NotUnlockable : UnlockError("This article can't be unlocked in Nostr Vault.")
        class Server(val code: Int, text: String) : UnlockError("The key server answered $code: $text")
        object Undecryptable : UnlockError("The key didn't open this article.")
    }

    private val prefs = context.getSharedPreferences("gated_article_keys", Context.MODE_PRIVATE)
    private val paidPrefs = context.getSharedPreferences("gated_article_paid_shares", Context.MODE_PRIVATE)
    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()

    /** Waits between checks; a test replaces it so it doesn't sleep. */
    internal var sleep: suspend (Long) -> Unit = { delay(it) }

    /** The signed-in account; a key and a payment belong to one reader. */
    val activeReader: String get() = nostrService.activeHexPubkey

    /**
     * Whether opening a gated article may ask the signer on its own. A local
     * key signs silently; a remote signer would prompt on every view.
     */
    val canCheckSilently: Boolean get() = configStore.config.value.activeSigningMode() == "local"

    /**
     * Keys already fetched, by reader pubkey and article coordinate. A key
     * belongs to the article address, not one version of it, so an edit keeps
     * it; a key that stops working is dropped (and, for Fanfares, asked for again).
     */
    private fun cacheKey(reader: String, coordinate: String) = "$reader|$coordinate"

    private fun storedAt(note: FeedNote): String? {
        val reader = nostrService.activeHexPubkey
        if (reader.isEmpty()) return null
        val coordinate = NIP10Thread.coordinate(note.kind, note.pubkey, note.tags) ?: return null
        return cacheKey(reader, coordinate)
    }

    /** The body from a key already on the device, else null. Any gated article; never signs or asks. */
    fun storedBody(note: FeedNote, gated: GatedArticle): String? {
        val stored = storedAt(note) ?: return null
        val key = prefs.getString(stored, null) ?: return null
        gated.decrypt(key)?.let { return it }
        prefs.edit().remove(stored).apply()
        return null
    }

    /**
     * The article body, if this reader can already read it: a stored key, or
     * (Fanfares only) the server says they paid. Throws [UnlockError.NotPaid]
     * when they haven't, [UnlockError.NotUnlockable] for any other gated article.
     */
    suspend fun open(note: FeedNote, gated: GatedArticle): String {
        if (nostrService.activeHexPubkey.isEmpty()) throw UnlockError.NotSignedIn
        val stored = storedAt(note) ?: throw UnlockError.Undecryptable
        storedBody(note, gated)?.let { return it }
        if (!gated.isFanfares) throw UnlockError.NotUnlockable
        val identifier = note.tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1) ?: throw UnlockError.Undecryptable
        val key = requestKey(note, gated, identifier)
        val body = gated.decrypt(key) ?: throw UnlockError.Undecryptable
        prefs.edit().putString(stored, key).apply()
        return body
    }

    // ── Paying (Fanfares only) ──────────────────────────────────────

    /**
     * Shares this reader has started paying, as "reader|coordinate|recipient".
     * A share is recorded BEFORE its zap goes out: a wallet that times out
     * may still have paid, and a share that might have been paid must never
     * be offered again.
     */
    private fun paidShares(): Set<String> = paidPrefs.getStringSet(PAID_KEY, null)?.toSet() ?: emptySet()

    private fun shareKey(note: FeedNote, share: GatedArticle.Share): String? =
        storedAt(note)?.let { "$it|${share.pubkey}" }

    /**
     * Shares not yet paid (or attempted). Empty means everything that can be
     * paid has been, and all that's left is waiting for the key.
     */
    fun unpaidShares(note: FeedNote, gated: GatedArticle): List<GatedArticle.Share> {
        val paid = paidShares()
        return gated.shares.filter { share -> shareKey(note, share)?.let { it !in paid } ?: true }
    }

    /** True once any money may have moved for this article. */
    fun hasPaid(note: FeedNote, gated: GatedArticle): Boolean =
        unpaidShares(note, gated).size < gated.shares.size

    private val paying = Mutex()

    /**
     * Zaps every share not already paid. Every recipient's lightning address
     * is found first, so a missing one fails before any money moves.
     *
     * Runs in the app scope: leaving the article (which cancels the screen's
     * scope) must not cut a payment off between shares or mid-wallet call.
     * One payment at a time, so a second tap or screen sees the shares the
     * first one recorded and never pays them again.
     */
    suspend fun pay(note: FeedNote, gated: GatedArticle) {
        if (!gated.isFanfares) throw UnlockError.NotUnlockable
        appScope.async { paying.withLock { payShares(note, gated) } }.await()
    }

    private suspend fun payShares(note: FeedNote, gated: GatedArticle) {
        if (!gated.isFanfares) throw UnlockError.NotUnlockable
        if (nostrService.activeHexPubkey.isEmpty()) throw UnlockError.NotSignedIn
        // A share that can't be recorded could be offered again: never pay one.
        val coordinate = NIP10Thread.coordinate(note.kind, note.pubkey, note.tags) ?: throw UnlockError.Undecryptable
        val due = unpaidShares(note, gated)
        for (share in due) {
            if (!hasLightningAddress(share.pubkey)) throw UnlockError.NoLightningAddress
        }
        for (share in due) {
            val key = shareKey(note, share) ?: throw UnlockError.Undecryptable
            record(key, paid = true)
            val result = try {
                zapSendService.zapNote(
                    noteId = note.id, notePubkey = share.pubkey, amountSats = share.sats,
                    message = "Unlocked with Nostr Vault", addressTag = coordinate,
                    extraReceiptRelays = gated.receiptRelays,
                )
            } catch (e: CancellationException) {
                // The wallet may already have been asked: keep the share.
                throw e
            } catch (e: Exception) {
                Result.failure(e)
            }
            result.exceptionOrNull()?.let { error ->
                // Failures before the wallet was asked to pay leave no money
                // moved, so the share can be offered again. A payment error
                // (a wallet timeout included) may still have paid: keep it.
                if (failedBeforePaying(error)) record(key, paid = false)
                throw error
            }
        }
    }

    private fun record(key: String, paid: Boolean) {
        val all = paidShares().toMutableSet()
        if (paid) all.add(key) else all.remove(key)
        // commit, not apply: the record is on disk before the zap goes out.
        paidPrefs.edit().putStringSet(PAID_KEY, all).commit()
    }

    private suspend fun hasLightningAddress(pubkey: String): Boolean {
        fun lookup(): Boolean {
            val profile = nostrService.profiles.value[pubkey] ?: return false
            return !profile.lud06.isNullOrBlank() || !profile.lud16.isNullOrBlank()
        }
        if (lookup()) return true
        nostrService.fetchMissingProfiles(listOf(pubkey))
        repeat(10) {
            sleep(500)
            if (lookup()) return true
        }
        return false
    }

    /**
     * Asks for the key until the server has seen the receipts. The receipt
     * is published by the author's lightning provider, so it lands seconds
     * after the payment, not with it, and Fanfares' server took about two
     * minutes to see a paid receipt on the first real unlock (2026-10-06).
     * So keep asking for about three minutes. Never pays.
     */
    suspend fun waitForKey(note: FeedNote, gated: GatedArticle): String {
        if (!gated.isFanfares) throw UnlockError.NotUnlockable
        var lastError: Exception = UnlockError.NotPaid
        for (seconds in WAIT_SECONDS) {
            sleep(seconds * 1000L)
            try {
                return open(note, gated)
            } catch (e: CancellationException) {
                throw e
            } catch (e: UnlockError.NotPaid) {
                lastError = e
            } catch (e: Exception) {
                lastError = e
                if (e is UnlockError.Server && e.code < 500) break
            }
        }
        throw lastError
    }

    /** The naddr the key server expects the NIP-98 event's content to be. */
    fun naddr(note: FeedNote, gated: GatedArticle, identifier: String): String? {
        val relay = gated.shares.firstOrNull { it.pubkey == note.pubkey }?.relay ?: gated.receiptRelays.firstOrNull()
        val tlv = GatedArticle.naddrTlv(identifier, relay, note.pubkey, note.kind) ?: return null
        return HavenBridge.encodeNaddrTlv(tlv)
    }

    private suspend fun requestKey(note: FeedNote, gated: GatedArticle, identifier: String): String {
        if (!gated.isFanfares) throw UnlockError.NotUnlockable
        val naddr = naddr(note, gated, identifier) ?: throw UnlockError.Undecryptable
        val auth = try {
            nostrService.signEventAsync(kind = 27235, content = naddr, tags = gated.httpAuthTags)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "Unlock request not signed: ${e.message}")
            null
        } ?: throw UnlockError.SignFailed
        val header = "Nostr " + Base64.encodeToString(
            EventPublisher.serializeSignedEvent(auth).toByteArray(), Base64.NO_WRAP,
        )
        return withContext(Dispatchers.IO) {
            val request = Request.Builder().url(gated.requestUrl).header("Authorization", header).get().build()
            http.newCall(request).execute().use { response ->
                val text = response.body?.string()?.trim().orEmpty()
                when (response.code) {
                    200 -> text
                    402 -> throw UnlockError.NotPaid
                    else -> {
                        Log.w(TAG, "Gated article: key request ${response.code}: ${text.take(200)}")
                        throw UnlockError.Server(response.code, text.take(120))
                    }
                }
            }
        }
    }

    internal companion object {
        const val TAG = "GatedArticleService"
        const val PAID_KEY = "paid_shares_v1"

        /** iOS waitForKey's backoff, about three minutes in all. */
        val WAIT_SECONDS = listOf(2, 3, 5, 5, 8, 8, 10, 10, 10, 15, 15, 15, 15, 15)

        /** NWC errors thrown before any request reaches the wallet (NWCService.sendNWCRequest). */
        private val NO_WALLET_DETAILS = setOf("No NWC connection configured", "Invalid NWC URI")

        /**
         * True only when the zap failed before the wallet was asked to pay:
         * LNURL, invoice or signing failures, or no wallet. Anything else,
         * a wallet timeout included, may have paid.
         */
        fun failedBeforePaying(error: Throwable): Boolean = when (error) {
            is ZapSendService.ZapError.LnurlFailed,
            is ZapSendService.ZapError.InvoiceFailed,
            is ZapSendService.ZapError.SignFailed,
            is ZapSendService.ZapError.NoWallet -> true
            is ZapSendService.ZapError.PaymentFailed -> error.detail in NO_WALLET_DETAILS
            else -> false
        }
    }
}
