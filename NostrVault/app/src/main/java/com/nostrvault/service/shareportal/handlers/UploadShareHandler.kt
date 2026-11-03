package com.nostrvault.service.shareportal.handlers

import com.nostrvault.shareportal.ShareAction

/**
 * Photos and videos. On Android the image/video SEND filters still sit on
 * MainActivity and `MainActivity.handleShareIntent` uploads them as before;
 * phase 3 moves those filters to SharePortalActivity and turns that code into
 * this handler (its own PR, with a device install). Until then no `upload`
 * intent is ever queued here, and one that turns up is shown as not ready
 * rather than guessed at. Twin: UploadShareHandler.swift, which is live on iOS.
 */
object UploadShareHandler : ShareHandler {
    override val action = ShareAction.UPLOAD
    override val isReady = false
    override val notReadyMessage =
        "Share photos and videos to Nostr Vault from your gallery's share sheet to upload them."
}
