package com.nostrvault.service.shareportal.handlers

import com.nostrvault.shareportal.ShareAction

/**
 * Keep a private copy, encrypted, in this device's vault only: the review
 * card (PrivateCopyReviewContent) seals and saves through PrivateCopyService.
 * Twin: PrivateCopyShareHandler.swift.
 */
object PrivateCopyShareHandler : ShareHandler {
    override val action = ShareAction.PRIVATE_COPY
    override val isReady = true
}
