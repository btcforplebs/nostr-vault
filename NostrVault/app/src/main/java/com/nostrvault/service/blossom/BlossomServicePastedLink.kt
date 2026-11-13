package com.nostrvault.service

/**
 * A Magic Paste of a link, already stored in this vault by [BlossomService.mirrorUrlToLocal]: send it on like a
 * picked or pasted image ([upload]), on the home vault's lane with a file note, so the owner's other open Media
 * tabs show it. No media server has it, so the note names none (the vault holds it). Twin of Apple
 * `BlossomService.saveFromMediaTab`.
 */
internal fun BlossomService.afterPastedLink(sha256: String) {
    val file = localBlobFile(sha256) ?: return
    val contentType = sniffContentType(file)
    homeVault.offerBlob(sha256, contentType, file)
    homeVault.offerFileNote(sha256, contentType, file.length(), emptyList())
    homeVault.drainSoon()
}
