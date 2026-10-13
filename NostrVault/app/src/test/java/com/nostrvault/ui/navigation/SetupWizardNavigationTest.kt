package com.nostrvault.ui.navigation

import android.content.Context
import android.net.Uri
import androidx.arch.core.executor.ArchTaskExecutor
import androidx.arch.core.executor.TaskExecutor
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavController
import androidx.navigation.NavDestination
import androidx.navigation.NavOptions
import androidx.navigation.Navigator
import androidx.navigation.createGraph
import com.nostrvault.ui.screens.settings.SETUP_INCOMPLETE_DESTINATION
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * Where the setup wizard goes, on a real androidx NavController: first run ends
 * on the Feed, a wizard opened over Settings (its "Setup Incomplete" banner, or a
 * config reset) goes back there, and setup finishing never rebuilds the graph.
 */
class SetupWizardNavigationTest {

    /** Stands in for the Compose navigator: pushes and pops, draws nothing. */
    @Navigator.Name("screen")
    private class ScreenNavigator : Navigator<NavDestination>() {
        override fun createDestination() = NavDestination(this)
        override fun navigate(entries: List<NavBackStackEntry>, navOptions: NavOptions?, navigatorExtras: Extras?) {
            entries.forEach { state.push(it) }
        }
        override fun popBackStack(popUpTo: NavBackStackEntry, savedState: Boolean) = state.pop(popUpTo, savedState)
    }

    /**
     * The nav host as NostrVaultNavHost runs it: `NavHost` builds a new graph,
     * and sets it, whenever its start destination changes. [followLiveFlag]
     * picks the start from the setup flag at every change, as master did;
     * otherwise it is the first one, as `remember { setupStartRoute(...) }` keeps it.
     */
    private class Host(setupComplete: Boolean, private val followLiveFlag: Boolean = false) {
        val nav = NavController(mockk<Context>(relaxed = true)).apply {
            navigatorProvider.addNavigator(ScreenNavigator())
        }
        private var setupComplete = setupComplete
        private val firstStart = setupStartRoute(setupComplete)
        private var start: String? = null

        init { compose() }

        /** The config's `hasCompletedSetup` changing, and the host recomposing. */
        fun setupComplete(now: Boolean) {
            openSetupWizardIfReset(nav, setupComplete, now)
            setupComplete = now
            compose()
        }

        private fun compose() {
            val route = if (followLiveFlag) setupStartRoute(setupComplete) else firstStart
            if (route == start) return
            start = route
            val screens = nav.navigatorProvider.getNavigator<ScreenNavigator>("screen")
            nav.graph = nav.createGraph(startDestination = route) {
                listOf(Screen.Feed, Screen.Settings, Screen.SetupWizard, Screen.Dashboard).forEach {
                    addDestination(screens.createDestination().apply { this.route = it.route })
                }
            }
        }

        val routes get() = nav.currentBackStack.value.mapNotNull { it.destination.route }
    }

    @Before fun setUp() {
        // NavController drives lifecycles, which check for the main thread, and
        // matches routes through Uri; neither exists on the JVM.
        ArchTaskExecutor.getInstance().setDelegate(object : TaskExecutor() {
            override fun executeOnDiskIO(runnable: Runnable) = runnable.run()
            override fun postToMainThread(runnable: Runnable) = runnable.run()
            override fun isMainThread() = true
        })
        mockkStatic(Uri::class)
        every { Uri.parse(any()) } answers {
            val text = firstArg<String>()
            mockk<Uri>(relaxed = true) { every { this@mockk.toString() } returns text }
        }
    }

    @After fun tearDown() {
        unmockkStatic(Uri::class)
        ArchTaskExecutor.getInstance().setDelegate(null)
    }

    @Test fun firstRunEndsOnTheFeedWithNothingToGoBackTo() {
        val host = Host(setupComplete = false)
        assertEquals(listOf(Screen.SetupWizard.route), host.routes)

        finishSetupWizard(host.nav)
        host.setupComplete(true)

        assertEquals(listOf(Screen.Feed.route), host.routes)
        assertNull(host.nav.previousBackStackEntry)
    }

    @Test fun theBannerOpensTheWizardAndFinishingItGoesBackToSettings() {
        val host = Host(setupComplete = true)
        host.nav.navigate(Screen.Settings.route)
        host.setupComplete(false) // a config reset: the wizard opens over Settings
        host.nav.popBackStack()   // the user backs out of it, and sees the banner

        host.nav.navigate(SETUP_INCOMPLETE_DESTINATION.route)
        finishSetupWizard(host.nav)
        host.setupComplete(true)

        assertEquals(listOf(Screen.Feed.route, Screen.Settings.route), host.routes)
    }

    @Test fun aConfigResetMidRunOpensTheWizardOverWhereTheUserIs() {
        val host = Host(setupComplete = true)
        host.nav.navigate(Screen.Dashboard.route)

        host.setupComplete(false)
        assertEquals(listOf(Screen.Feed.route, Screen.Dashboard.route, Screen.SetupWizard.route), host.routes)

        finishSetupWizard(host.nav)
        host.setupComplete(true)
        assertEquals(listOf(Screen.Feed.route, Screen.Dashboard.route), host.routes)
    }

    @Test fun onlyAResetOpensTheWizard() {
        val host = Host(setupComplete = false)
        host.setupComplete(false)
        assertEquals(listOf(Screen.SetupWizard.route), host.routes)

        val done = Host(setupComplete = true)
        done.setupComplete(true)
        assertEquals(listOf(Screen.Feed.route), done.routes)
    }

    /**
     * Why the start is fixed: on a start that follows the live flag, the graph
     * rebuilt when setup finishes drops the whole back stack (NavController's
     * setGraph, "different graph"), and Settings is gone.
     */
    @Test fun aStartThatFollowsTheLiveFlagDropsTheBackStack() {
        val host = Host(setupComplete = true, followLiveFlag = true)
        host.nav.navigate(Screen.Settings.route)
        host.setupComplete(false)
        assertEquals(listOf(Screen.SetupWizard.route), host.routes)

        finishSetupWizard(host.nav)
        host.setupComplete(true)
        assertEquals(listOf(Screen.Feed.route), host.routes)
    }
}
