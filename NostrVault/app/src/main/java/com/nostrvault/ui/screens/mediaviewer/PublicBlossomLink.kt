package com.nostrvault.ui.screens

/**
 * The link to share for a Blossom item: its own URL when it has one, otherwise
 * the first public mirror + sha256. Never a path on this phone.
 */
internal fun publicBlossomLink(item: BlossomMediaItem, mirrors: List<String>): String {
    if (item.displayUrl.startsWith("http")) return item.displayUrl
    val mirror = mirrors.firstOrNull { !it.contains("localhost") && !it.contains("127.0.0.1") }
    return if (mirror != null) "$mirror/${item.sha256}" else item.displayUrl
}
