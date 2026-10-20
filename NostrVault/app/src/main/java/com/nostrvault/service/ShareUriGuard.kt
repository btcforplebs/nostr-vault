package com.nostrvault.service

import android.content.Context
import android.net.Uri

/**
 * Whether a URI another app handed us may be read for an upload: only
 * another app's content provider ([isReadableShare]). The provider is looked
 * up so one of ours is refused whatever its name. Every path where another
 * app picks the URI goes through this: the share sheet, and the clipboard
 * (the `nostrvault://mediapaste` link and the composer's paste).
 * In-app attachments are our own `file://` cache copies and must not.
 */
fun Context.readsForeignUri(uri: Uri): Boolean {
    val host = shareHost(uri.authority)
    val owner = host?.let { runCatching { packageManager.resolveContentProvider(it, 0)?.packageName }.getOrNull() }
    return isReadableShare(uri.scheme, uri.authority, owner, packageName)
}

/** Shown when another app's URI is refused. */
const val FOREIGN_URI_REFUSED = "That file can't be uploaded"

/**
 * Whether a shared URI may be read for an upload. Only `content://` from
 * another app's provider: a `file://` URI, or one naming a provider of ours,
 * is opened with this app's own permissions, so any app could have us upload
 * our private files (the config, with its keys) to Blossom. [providerPackage]
 * is who the system says owns the authority, or null when it can't see it
 * (another app's provider can be hidden by package visibility).
 */
internal fun isReadableShare(scheme: String?, authority: String?, providerPackage: String?, ownPackage: String): Boolean {
    if (!scheme.equals("content", ignoreCase = true)) return false
    val host = shareHost(authority) ?: return false
    val own = ownPackage.lowercase()
    if (host == own || host.startsWith("$own.")) return false
    return providerPackage != ownPackage
}

/** The provider part of an authority, without a cross-profile `userId@` prefix. */
internal fun shareHost(authority: String?): String? =
    authority?.substringAfterLast('@')?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }

/**
 * The URIs in a share's `EXTRA_STREAM`: one or a list, as the sender put it.
 * Anything that isn't a [Uri] is dropped rather than cast, so a malformed
 * share (a list of path strings) can't crash the app.
 */
internal fun sharedStreamUris(stream: Any?): List<Uri> = when (stream) {
    is Uri -> listOf(stream)
    is Iterable<*> -> stream.filterIsInstance<Uri>()
    else -> emptyList()
}
