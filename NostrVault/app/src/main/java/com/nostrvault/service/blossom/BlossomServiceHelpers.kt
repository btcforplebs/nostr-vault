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

/**
 * Nothing to delete from: no server to target, or each one was the owner's own vault. An error in
 * every viewer, as on iOS (the feed viewer showed it as a success toast, the gallery as an error).
 */
const val DELETE_NO_MIRRORS_MESSAGE = "No mirrors to delete from"

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

/**
 * What a Delete from mirrors says, and whether it is a success. A server left alone because the
 * owner runs it is named ("Skipped: studio-mac.example.net (your own vault)"), so a delete that
 * skipped one never reads as plain "Deleted from mirrors". Same words as iOS
 * `MediaDeleteWording.mirrorsReport` and the web vault's `skippedLine` (blossom-gallery.js).
 */
fun mirrorsDeleteMessage(report: BlossomService.MirrorDeleteResult): Pair<String, Boolean> {
    val skipped = skippedLine(report.skippedHosts)
    fun withSkipped(text: String) = if (skipped.isEmpty()) text else "$text. $skipped"
    return when {
        report.failed.isNotEmpty() -> withSkipped(deleteEverywhereLeftover(localDeleted = true, mirrors = report)!!) to false
        report.deleted.isNotEmpty() -> withSkipped("Deleted from mirrors") to true
        else -> withSkipped(DELETE_NO_MIRRORS_MESSAGE) to false
    }
}

/** "Skipped: a (your own vault)", "Skipped: a and b (your own vaults)", or "" for none. */
internal fun skippedLine(hosts: List<String>): String = when (hosts.size) {
    0 -> ""
    1 -> "Skipped: ${hosts[0]} (your own vault)"
    else -> "Skipped: ${joinPlaces(hosts)} (your own vaults)"
}

/** "a", "a and b", "a, b and c". */
internal fun joinPlaces(places: List<String>): String = when (places.size) {
    0 -> ""
    1 -> places[0]
    else -> places.dropLast(1).joinToString(", ") + " and " + places.last()
}
