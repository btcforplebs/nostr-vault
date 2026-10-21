package com.nostrvault.relay

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import org.junit.Assert.assertEquals
import org.junit.Test

class AppForegroundReporterTest {
    private class Owner : LifecycleOwner {
        val registry = LifecycleRegistry.createUnsafe(this)
        override val lifecycle: Lifecycle get() = registry
    }

    @Test
    fun reportsBackgroundUntilStartedThenFollowsTheLifecycle() {
        val owner = Owner()
        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_CREATE)
        val reports = mutableListOf<Boolean>()
        owner.registry.addObserver(AppForegroundReporter { reports += it })
        assertEquals(listOf(false), reports)

        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_START)
        assertEquals(listOf(false, true), reports)

        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
        assertEquals(listOf(false, true, false), reports)

        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_START)
        assertEquals(listOf(false, true, false, true), reports)
    }
}
