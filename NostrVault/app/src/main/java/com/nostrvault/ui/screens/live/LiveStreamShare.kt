package com.nostrvault.ui.screens.live

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import com.nostrvault.data.model.LiveStream
import com.nostrvault.data.model.QuoteRef
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenQuoteDecoder
import com.nostrvault.ui.components.threadLink

/**
 * Sharing a live stream: as a note, as a link, or to another app.
 *
 * The link is the nostrvault.app post page with the stream's `naddr`
 * (`/thread/<naddr>`), which names the replaceable 30311 event itself, so it
 * keeps pointing at the stream across the host's republishes.
 */
internal object LiveStreamShare {

    /** The stream's `naddr`: its signer, `d` tag and kind. Null when the `d` tag cannot be encoded. */
    fun naddr(stream: LiveStream): String? =
        HavenBridge.encodeNaddr(stream.identifier, stream.authorPubkey, LiveStream.KIND)

    /** The nostrvault.app page for the stream, or null without an naddr. */
    fun webLink(stream: LiveStream): String? = naddr(stream)?.let(::threadLink)

    /**
     * What "Share as a note" starts the composer with: "Live now: <host>" and
     * the stream's `nostr:naddr1…`, nothing else. The naddr draws the Live
     * card, which already carries the picture, the title and the player, so a
     * picture or `.m3u8` line here only drew them twice. The title is left to
     * the card: Lot Radio republishes one 30311 for every show, so a title in
     * the text names last hour's show while the card shows this one.
     * iOS / web: LiveStreamShare.noteText, live-chat.js noteText.
     */
    fun noteText(hostName: String?, naddr: String?): String {
        val heading = "Live now: ${hostName?.trim()?.takeIf { it.isNotEmpty() } ?: "a stream"}"
        return if (naddr != null) "$heading\n\nnostr:$naddr" else heading
    }

    fun noteText(stream: LiveStream, hostName: String?): String =
        noteText(hostName ?: stream.hostPubkey.take(8), naddr(stream))

    /**
     * NIP-18 `q` tags for the live streams a note's text quotes: one
     * `["q", "30311:<pubkey>:<d>", ""]` per `nostr:naddr1…` naming a kind
     * 30311, once each. No relay hint, as for any quote this app posts.
     */
    fun quoteTags(content: String, decoder: QuoteRef.Decoder = HavenQuoteDecoder): List<List<String>> =
        QuoteRef.identifiers(content)
            .filter { it.startsWith("naddr1", ignoreCase = true) }
            .mapNotNull { decoder.naddrToCoordinate(it) }
            .filter { it.kind == LiveStream.KIND }
            .map { listOf("q", "${it.kind}:${it.pubkey}:${it.dTag}", "") }
            .distinct()

    /** Hands the stream's link to the system share sheet. */
    fun share(context: Context, stream: LiveStream) {
        val link = webLink(stream) ?: stream.streamingUrl ?: return
        val text = stream.title?.let { "$it\n$link" } ?: link
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
        }
        context.startActivity(Intent.createChooser(intent, "Share stream"))
    }

    /** Copies the stream's link. @return false when there is none to copy. */
    fun copyLink(context: Context, stream: LiveStream): Boolean {
        val link = webLink(stream) ?: return false
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("Stream link", link))
        return true
    }
}
