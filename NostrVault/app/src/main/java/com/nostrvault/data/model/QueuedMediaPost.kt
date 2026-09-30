package com.nostrvault.data.model

import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * A composed note whose media is saved on this device but has not yet reached
 * any outside Blossom server, so it cannot be published yet.
 *
 * A note that embeds a `localhost` media URL is a broken image for everyone
 * else, so the composer never publishes one. It used to *cancel the post*
 * instead — one sleeping Mac vault was enough to throw away a post whose photo
 * was already safe in the phone's own Blossom. Now the post waits here, on
 * disk, and `MediaPostQueue` sends it once an outside server accepts the blob.
 *
 * Everything the composer would have put in the event is kept except the
 * parts that depend on the final media URLs: those lines of content, the
 * hashtags read from the finished content, and the `imeta` tags are rebuilt by
 * [assembled] once every attachment has a URL — the same order and the same
 * [NoteTagging] helpers `ComposeNoteViewModel.publish()` uses, so a queued post
 * and a direct post come out identical.
 *
 * The Swift twin lives at `HavenApp/HavenApp/Models/QueuedMediaPost.swift`.
 */
@Serializable
data class QueuedMediaPost(
    val id: String = UUID.randomUUID().toString(),
    /** Epoch milliseconds. */
    val createdAt: Long = System.currentTimeMillis(),
    /**
     * npub that composed it. The signer follows the *active* account, so a
     * post is only sent while that account is active again — otherwise it
     * would go out under someone else's name.
     */
    val accountNpub: String,
    /** Text with mentions already converted to `nostr:` references. */
    val body: String,
    /** The attachments in content order. */
    val media: List<Media>,
    /** `\nnostr:note1…` for a quote post, appended after the media lines. */
    val quoteSuffix: String? = null,
    /** Reply, quote and mention tags. Hashtags and `imeta` are added by [assembled]. */
    val baseTags: List<List<String>>,
    val attempts: Int = 0,
    /** Epoch milliseconds of the last retry, if any. */
    val lastAttempt: Long? = null,
) {
    @Serializable
    data class Media(
        /** Blossom key. The blob is already in this device's relay under it. */
        val sha256: String? = null,
        val mimeType: String? = null,
        /** null until an outside server has accepted the blob. */
        val url: String? = null,
        val pixelWidth: Int? = null,
        val pixelHeight: Int? = null,
        val alt: String? = null,
        val byteCount: Long? = null,
    ) {
        fun descriptor(): NoteTagging.MediaDescriptor = NoteTagging.MediaDescriptor(
            url = url.orEmpty(),
            mimeType = mimeType,
            sha256 = sha256,
            pixelWidth = pixelWidth,
            pixelHeight = pixelHeight,
            alt = alt,
            byteCount = byteCount,
        )
    }

    /** The finished event body: content and tags. */
    data class Assembled(val content: String, val tags: List<List<String>>)

    /** Attachments still waiting for an outside server. */
    val pendingMedia: List<Media> get() = media.filter { it.url == null }

    val isReady: Boolean get() = pendingMedia.isEmpty()

    /** The event content and tags, or null while any attachment lacks a URL. */
    fun assembled(): Assembled? {
        if (!isReady) return null
        val content = buildString {
            append(body)
            for (item in media) append("\n").append(item.url)
            quoteSuffix?.let { append(it) }
        }
        val tags = baseTags.toMutableList()
        tags.addAll(NoteTagging.hashtagTags(content))
        tags.addAll(NoteTagging.imetaTags(media.map { it.descriptor() }))
        return Assembled(content, tags)
    }
}

/**
 * How a post's upload ended, in words a user can act on. Kept apart from the
 * screen so the cases cannot quietly collapse back into one message — they
 * used to share "Check your connection", which sent us looking at the network
 * when the photo was sitting safely in the phone's own relay.
 */
object MediaUploadOutcomeMessage {
    /**
     * No outside Blossom server is configured at all: the post can never be
     * sent as-is, so it is not queued. "Settings → Blossom" is the row that
     * opens the Blossom Servers screen on Android.
     */
    const val NO_OUTSIDE_SERVER =
        "Your post wasn't sent: no outside media server is set up, so nobody else could see this photo. Add your Mac or another server in Settings → Blossom, then post again."

    /** The blob never reached this device's own relay. */
    const val NOT_SAVED_ON_DEVICE =
        "Your post wasn't sent: the photo couldn't be saved on this device. Try again in a moment."

    /** Shown when a waiting post finally goes out. */
    const val SENT = "Your waiting post was sent."

    /**
     * Saved here, waiting for an outside server. [hosts] are the servers that
     * did not answer; [macHost] is the Mac vault's host if one is configured.
     */
    fun queued(hosts: List<String>, macHost: String?): String {
        val waitingFor = when {
            macHost != null && macHost in hosts ->
                if (hosts.size == 1) "your Mac vault" else "your Mac vault or another media server"
            hosts.size == 1 -> hosts.first()
            else -> "one of your media servers"
        }
        return "Saved on this device. Your post will send itself as soon as $waitingFor answers."
    }
}
