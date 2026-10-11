package com.nostrvault.service

/** Whether one Blossom server holds a blob. */
enum class BlobPresence {
    PRESENT,
    ABSENT,
    /** The server did not answer (offline, timeout, 5xx), so we do not know. */
    UNREACHABLE,
}

/** The decision behind a HEAD check, split out so it can be tested without a server. Matches iOS. */
/**
 * [finalUrl] is where redirects ended. A blob's own location names its hash;
 * a redirect that lands anywhere else is a placeholder.
 */
fun blobPresence(
    statusCode: Int,
    contentType: String?,
    contentLength: String?,
    sha256: String? = null,
    finalUrl: String? = null,
): BlobPresence = when (statusCode) {
    in 200..299 -> when {
        sha256 != null && finalUrl != null && !finalUrl.lowercase().contains(sha256.lowercase()) -> BlobPresence.ABSENT
        contentType?.lowercase()?.startsWith("text/html") == true -> BlobPresence.ABSENT
        contentLength?.toLongOrNull() == 0L -> BlobPresence.ABSENT
        else -> BlobPresence.PRESENT
    }
    in 400..499 -> BlobPresence.ABSENT
    else -> BlobPresence.UNREACHABLE
}
