package com.nostrvault.ui.screens.live

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import com.nostrvault.data.model.LiveStream
import com.nostrvault.relay.HavenBridge
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
     * What "Share as a note" starts the composer with: the title, the cover
     * picture and the HLS link on lines of their own, so a client that only
     * reads links shows the picture and a playable video, then the
     * `nostr:naddr1…` that a NIP-53 client opens as the stream itself.
     */
    fun noteText(title: String?, imageUrl: String?, streamingUrl: String?, naddr: String?): String =
        listOfNotNull(
            "Live now: ${title?.trim()?.takeIf { it.isNotEmpty() } ?: "a stream"}",
            imageUrl,
            streamingUrl,
            naddr?.let { "nostr:$it" },
        ).joinToString("\n")

    fun noteText(stream: LiveStream): String =
        noteText(stream.title, stream.imageUrl ?: stream.previewImageUrls.firstOrNull(), stream.streamingUrl, naddr(stream))

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
