package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Test

class AutoMirrorOnOpenRuleTest {
    private var enabled = true
    private var ready = false
    private var runs = 0
    private val rule = AutoMirrorOnOpenRule(enabled = { enabled }, relayReady = { ready }, runIfDue = { runs++; true })

    @Test
    fun `opening the app with the relay up runs it`() {
        ready = true
        rule.appOpened()
        assertEquals(1, runs)
    }

    @Test
    fun `opening before the relay serves waits for it, then runs once`() {
        rule.appOpened()
        assertEquals(0, runs)
        ready = true
        rule.relayCameUp()
        assertEquals(1, runs)
        // A later relay restart is not an app open.
        rule.relayCameUp()
        assertEquals(1, runs)
    }

    @Test
    fun `a relay start with no app open does not run it`() {
        ready = true
        rule.relayCameUp()
        assertEquals(0, runs)
    }

    @Test
    fun `off in settings, it never runs, even when switched on later without an open`() {
        enabled = false
        ready = true
        rule.appOpened()
        assertEquals(0, runs)
        enabled = true
        rule.relayCameUp()
        assertEquals(0, runs)
    }

    @Test
    fun `every open asks, the 3 hour rule decides`() {
        ready = true
        rule.appOpened()
        rule.appOpened()
        assertEquals(2, runs)
    }
}
