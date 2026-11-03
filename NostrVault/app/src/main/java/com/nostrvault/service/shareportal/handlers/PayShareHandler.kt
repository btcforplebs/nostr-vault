package com.nostrvault.service.shareportal.handlers

import com.nostrvault.shareportal.PayShareTarget
import com.nostrvault.shareportal.ShareAction
import com.nostrvault.shareportal.ShareIntent

/**
 * Pay or zap (lane D). The review card ([com.nostrvault.ui.screens.shareportal.PayReviewViewModel])
 * does the work; this says the action is ready and what the share points at.
 * Twin: PayShareHandler.swift.
 *
 * Money rules (Tron review, mandatory): nothing is paid without the card's
 * confirm; an invoice with no amount is refused; an LNURL invoice for a
 * different amount than asked is refused (LUD-06); once a wallet call for an
 * LNURL or zap has started, this share never pays again, even after the app
 * is killed and the card comes back.
 */
object PayShareHandler : ShareHandler {
    override val action = ShareAction.PAY
    override val isReady = true

    fun target(intent: ShareIntent): PayShareTarget? =
        PayShareTarget.find(intent.source.url, intent.source.text, intent.source.selection)
}
