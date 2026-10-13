package com.nostrvault.service

import com.nostrvault.data.model.TrustPath
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A trust path that keeps up with your follows on every screen (iOS LiveTrustPath). */
@OptIn(ExperimentalCoroutinesApi::class)
class LiveTrustPathTest {
    private val follows = MutableStateFlow(setOf("friend"))
    private var traces = 0
    private val trust = mockk<TrustPathService> {
        every { webChanged } returns follows.map { }
        coEvery { path(any()) } answers {
            traces++
            val author = firstArg<String>()
            if (author in follows.value) TrustPath(TrustPath.Reach.FOLLOW, emptyList(), false)
            else TrustPath(TrustPath.Reach.OUTSIDE, emptyList(), false)
        }
    }

    @Test fun `following them flips the path without asking again`() = runTest(UnconfinedTestDispatcher()) {
        val live = LiveTrustPath(trust, backgroundScope)
        live.track("stranger")
        assertEquals(TrustPath.Reach.OUTSIDE, live.path.value?.reach)
        follows.value = follows.value + "stranger"
        assertEquals(TrustPath.Reach.FOLLOW, live.path.value?.reach)
        follows.value = follows.value - "stranger"
        assertEquals(TrustPath.Reach.OUTSIDE, live.path.value?.reach)
    }

    @Test fun `the same author again does not trace again`() = runTest(UnconfinedTestDispatcher()) {
        val live = LiveTrustPath(trust, backgroundScope)
        live.track("stranger")
        live.track("stranger")
        assertEquals(1, traces)
    }

    @Test fun `null stops and clears`() = runTest(UnconfinedTestDispatcher()) {
        val live = LiveTrustPath(trust, backgroundScope)
        live.track("stranger")
        live.track(null)
        assertNull(live.path.value)
        assertNull(live.author)
        follows.value = follows.value + "stranger"
        assertNull(live.path.value)
        assertEquals(1, traces)
    }
}
