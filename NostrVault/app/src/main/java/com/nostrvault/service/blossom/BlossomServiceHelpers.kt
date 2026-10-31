package com.nostrvault.service

/**
 * The blob hash a URL names: its last path part is 64 hex, optionally with an
 * extension. Null otherwise; BUD-02 lets a server pick any URL for a blob.
 * Port of iOS `MediaCacheService.blossomHash(in:)`.
 */
fun blossomHashInUrl(url: String): String? {
    val last = url.substringBefore('#').substringBefore('?').trimEnd('/').substringAfterLast('/')
    val match = BLOSSOM_HASH_PATH.matchEntire(last) ?: return null
    return match.groupValues[1].lowercase()
}

/**
 * Said when a delete has nothing to name the file by: a delete that silently did nothing looked
 * like one that worked. Same words as iOS `MediaGalleryView.deleteHash(for:)`.
 */
const val DELETE_NO_HASH_MESSAGE = "Can't delete: this file's hash could not be read"

/** A blob hash a delete can use: 64 hex. */
fun isBlobHash(value: String): Boolean = value.length == 64 && value.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }

private val BLOSSOM_HASH_PATH = Regex("^([a-fA-F0-9]{64})(\\.[a-zA-Z0-9]+)?$")

/** "blossom.primal.net" for a server's base URL; the URL itself when it has no host. */
internal fun serverHost(url: String): String =
    runCatching { java.net.URI(url).host }.getOrNull() ?: url

/**
 * What a Delete everywhere left behind, or null when nothing is left. Names
 * each place so a partial delete can't pass for a full one. Port of iOS
 * `BlossomService.deleteEverywhereLeftover`.
 */
fun deleteEverywhereLeftover(localDeleted: Boolean, mirrors: BlossomService.MirrorDeleteResult): String? {
    val places = mirrors.failedHosts.toMutableList()
    if (!localDeleted) places += "this device"
    if (places.isEmpty()) return null
    return "Still on " + joinPlaces(places)
}

/** "a", "a and b", "a, b and c". */
internal fun joinPlaces(places: List<String>): String = when (places.size) {
    0 -> ""
    1 -> places[0]
    else -> places.dropLast(1).joinToString(", ") + " and " + places.last()
}
