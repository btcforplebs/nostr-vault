package com.nostrvault.ui.screens.profile

import com.nostrvault.service.MediaSaveService

/**
 * What a profile Media grid tile's long-press offers, in iOS
 * `MediaGridItem` order. The profile grid never offers Delete or Open Note.
 */
enum class ProfileMediaAction {
    COPY_LINK,
    SAVE_TO_PHOTOS,
    SAVE_TO_VAULT,
    MIRROR_TO_BLOSSOM,
    MARK_404,
    UNMARK_404,
    REPORT,
    BLOCK,
}

/**
 * The menu for one tile. Save to Photos is for pictures and video only
 * (known by extension, as iOS types the tile); a
 * file already in the vault offers Mirror to Blossom instead of Save to
 * Vault, and only once a server is known to lack it. Report and Block
 * appear only on someone else's media ([moderationTarget] non-null).
 */
internal fun profileMediaMenu(
    url: String,
    inVault: Boolean,
    needsMirror: Boolean,
    is404: Boolean,
    moderationTarget: String?,
): List<ProfileMediaAction> = buildList {
    add(ProfileMediaAction.COPY_LINK)
    if (MediaSaveService.mimeTypeForExtension(url) != null) add(ProfileMediaAction.SAVE_TO_PHOTOS)
    if (!inVault) add(ProfileMediaAction.SAVE_TO_VAULT)
    else if (needsMirror) add(ProfileMediaAction.MIRROR_TO_BLOSSOM)
    add(if (is404) ProfileMediaAction.UNMARK_404 else ProfileMediaAction.MARK_404)
    if (moderationTarget != null) {
        add(ProfileMediaAction.REPORT)
        add(ProfileMediaAction.BLOCK)
    }
}

/** The blob hash a Blossom URL is named by (`…/<sha256>[.ext]`), or null. */
internal fun blossomHashOf(url: String): String? {
    val name = url.substringBefore('?').substringBefore('#').substringAfterLast('/').substringBefore('.')
    return name.lowercase().takeIf { it.length == 64 && it.all { c -> c in "0123456789abcdef" } }
}
