package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** With several accounts, each notification names the account it is for. */
class NotificationAccountLabelTest {

    private val owner = "npub1ownerownerownerownerownerownerownerownerownerownerowner0"
    private val second = "npub1secondsecondsecondsecondsecondsecondsecondsecondsecond"

    private fun label(npub: String, accounts: List<String>, name: String?) =
        LocalNotificationService.accountLabel(npub, accounts, name)

    @Test fun noLabelWithOneAccount() {
        assertNull(label(owner, listOf(owner), "Logen"))
    }

    @Test fun namesTheAccountWithTwo() {
        assertEquals("Shop", label(second, listOf(owner, second), "Shop"))
    }

    @Test fun shortNpubWithoutAName() {
        assertEquals("npub1sec…cond", label(second, listOf(owner, second), "  "))
    }

    @Test fun noLabelForAnAccountNoLongerHeld() {
        assertNull(label(second, listOf(owner, "npub1other"), "Shop"))
    }
}
