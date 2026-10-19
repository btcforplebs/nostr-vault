package com.nostrvault.service

import android.content.Context
import android.util.Base64
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.GatedArticle
import com.nostrvault.relay.HavenBridge
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Unlocks gated ("zap N sats to unlock") articles. iOS GatedArticleService.
 *
 * The key server is the only judge of whether a zap counted, so this never
 * decides "paid" itself: it asks, and a 402 means not yet. It never pays: like
 * the iPhone, Nostr Vault opens an article that was paid for on the web or in
 * another client and sends the reader there to buy it. The one thing it signs
 * is the NIP-98 HTTP auth event (kind 27235, a request header, never
 * published) that names the key URL.
 */
@Singleton
class GatedArticleService @Inject constructor(
    @ApplicationContext context: Context,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
) {
    sealed class UnlockError(message: String) : Exception(message) {
        object NotSignedIn : UnlockError("Sign in to unlock this article.")
        object SignFailed : UnlockError("Your signer didn't sign the unlock request.")
        object NotPaid : UnlockError("The author hasn't seen your zap yet.")
        class Server(val code: Int, text: String) : UnlockError("The key server answered $code: $text")
        object Undecryptable : UnlockError("The key didn't open this article.")
    }

    private val prefs = context.getSharedPreferences("gated_article_keys", Context.MODE_PRIVATE)
    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()

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
     * it; a key that stops working is dropped and asked for again.
     */
    private fun cacheKey(reader: String, coordinate: String) = "$reader|$coordinate"

    /**
     * The article body, if this reader can already read it: a stored key, or
     * the server says they paid. Throws [UnlockError.NotPaid] when they haven't.
     */
    suspend fun open(note: FeedNote, gated: GatedArticle): String {
        val reader = nostrService.activeHexPubkey
        if (reader.isEmpty()) throw UnlockError.NotSignedIn
        val identifier = note.tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1) ?: throw UnlockError.Undecryptable
        val stored = cacheKey(reader, "${note.kind}:${note.pubkey}:$identifier")
        prefs.getString(stored, null)?.let { key ->
            gated.decrypt(key)?.let { return it }
            prefs.edit().remove(stored).apply()
        }
        val key = requestKey(note, gated, identifier)
        val body = gated.decrypt(key) ?: throw UnlockError.Undecryptable
        prefs.edit().putString(stored, key).apply()
        return body
    }

    /** The naddr the key server expects the NIP-98 event's content to be. */
    fun naddr(note: FeedNote, gated: GatedArticle, identifier: String): String? {
        val relay = gated.shares.firstOrNull { it.pubkey == note.pubkey }?.relay ?: gated.receiptRelays.firstOrNull()
        val tlv = GatedArticle.naddrTlv(identifier, relay, note.pubkey, note.kind) ?: return null
        return HavenBridge.encodeNaddrTlv(tlv)
    }

    private suspend fun requestKey(note: FeedNote, gated: GatedArticle, identifier: String): String {
        val naddr = naddr(note, gated, identifier) ?: throw UnlockError.Undecryptable
        val auth = try {
            nostrService.signEventAsync(kind = 27235, content = naddr, tags = gated.httpAuthTags)
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

    private companion object {
        const val TAG = "GatedArticleService"
    }
}
