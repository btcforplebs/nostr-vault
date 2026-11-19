package com.nostrvault.ui.screens.dm

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** NV_MESSAGES_UX_CHECK 2026-11-18, B7 and B10 on Android. */
class DMInboxNavigationTest {
    @Test fun `Back closes search first, then Requests, then leaves`() {
        assertEquals(DMInboxBack.CLOSE_SEARCH, DMInboxBack.of(searching = true, inRequests = true))
        assertEquals(DMInboxBack.CLOSE_SEARCH, DMInboxBack.of(searching = true, inRequests = false))
        assertEquals(DMInboxBack.CLOSE_REQUESTS, DMInboxBack.of(searching = false, inRequests = true))
        assertEquals(DMInboxBack.LEAVE, DMInboxBack.of(searching = false, inRequests = false))
    }

    @Test fun `an inbox with only requests says so instead of going blank`() {
        assertTrue(dmInboxOnlyRequests(inboxEmpty = true, requestCount = 2, inRequests = false, searching = false))
        assertFalse("inside Requests the list shows them", dmInboxOnlyRequests(true, 2, inRequests = true, searching = false))
        assertFalse("a search has its own empty line", dmInboxOnlyRequests(true, 2, inRequests = false, searching = true))
        assertFalse("no requests: the usual empty state", dmInboxOnlyRequests(true, 0, inRequests = false, searching = false))
        assertFalse(dmInboxOnlyRequests(inboxEmpty = false, requestCount = 2, inRequests = false, searching = false))
    }

    @Test fun `the requests line counts`() {
        assertEquals("1 message request is waiting", dmRequestsLine(1))
        assertEquals("3 message requests are waiting", dmRequestsLine(3))
    }
}
