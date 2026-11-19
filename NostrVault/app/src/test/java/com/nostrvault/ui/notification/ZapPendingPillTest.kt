package com.nostrvault.ui.notification

import com.nostrvault.service.ZapSendService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** An unconfirmed zap, or "zap again?", is a plain pill that times out, never an error (ZapConfirm). */
class ZapPendingPillTest {
    @Test fun `unconfirmed and ask-again are pending, real failures stay errors`() {
        assertTrue(isZapPending(ZapSendService.ZapError.MayStillArrive()))
        assertTrue(isZapPending(ZapSendService.ZapError.StillPending()))
        assertFalse(isZapPending(ZapSendService.ZapError.PaymentFailed("refused")))
        assertFalse(isZapPending(RuntimeException("x")))
    }

    @Test fun `a pending pill is a result that times out`() {
        val pill = ZapNotification(recipientName = "Bob", amountSats = 21, status = ZapStatus.PENDING("Sent."))
        assertEquals(PillLevel.RESULT, pill.level)
        assertEquals(6_000L, pill.autoDismissMs)
    }
}
