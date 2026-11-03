package com.nostrvault.service.shareportal.handlers

import com.nostrvault.shareportal.ShareAction

/**
 * Picture or video post (NIP-68 / NIP-71): the review card
 * (MediaPostReviewContent) uploads and publishes through
 * MediaPostSharePublisher. Twin: MediaPostShareHandler.swift.
 */
object MediaPostShareHandler : ShareHandler {
    override val action = ShareAction.MEDIA_POST
    override val isReady = true
}
