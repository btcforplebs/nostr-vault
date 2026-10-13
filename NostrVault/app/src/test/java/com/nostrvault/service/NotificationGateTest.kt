package com.nostrvault.service

import com.nostrvault.relay.PushPrefs
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Whether a marker shows at all, pill or tray: the phone-notifications switch
 * and the kind's own switch both decide, in front and behind alike.
 */
class NotificationGateTest {

    private val all = PushPrefs(mentions = true, replies = true, dms = true, zaps = true,
        reactions = true, reposts = true, follows = true)
    private val none = PushPrefs(mentions = false, replies = false, dms = false, zaps = false,
        reactions = false, reposts = false, follows = false)
    private val kinds = listOf("mention", "reply", "quote", "dm", "giftwrap", "zap", "reaction", "repost", "follow", "followers")

    private fun mayShow(type: String, pushOn: Boolean, prefs: PushPrefs, fg: Boolean) =
        LocalNotificationService.mayShow(type, pushOn, prefs, fg)

    @Test fun aSwitchedOffKindShowsNothingInFrontOrBehind() {
        for (type in kinds) for (fg in listOf(true, false)) {
            assertFalse("$type fg=$fg", mayShow(type, pushOn = true, prefs = none, fg = fg))
        }
    }

    @Test fun eachKindAnswersToItsOwnSwitch() {
        assertFalse(mayShow("mention", true, all.copy(mentions = false), true))
        assertFalse(mayShow("quote", true, all.copy(mentions = false), true))
        assertFalse(mayShow("reply", true, all.copy(replies = false), true))
        assertFalse(mayShow("zap", true, all.copy(zaps = false), true))
        assertFalse(mayShow("reaction", true, all.copy(reactions = false), true))
        assertFalse(mayShow("repost", true, all.copy(reposts = false), true))
        assertFalse(mayShow("follow", true, all.copy(follows = false), true))
        assertFalse(mayShow("followers", true, all.copy(follows = false), true))
        assertTrue(mayShow("mention", true, all.copy(replies = false), true))
    }

    @Test fun everyKindSwitchedOnShowsInFront() {
        for (type in kinds) assertTrue(type, mayShow(type, pushOn = true, prefs = all, fg = true))
    }

    @Test fun phoneNotificationsOffLeavesOnlyTheDmPill() {
        for (type in kinds) {
            val dm = type == "dm" || type == "giftwrap"
            if (dm) assertTrue(type, mayShow(type, pushOn = false, prefs = all, fg = true))
            else assertFalse(type, mayShow(type, pushOn = false, prefs = all, fg = true))
            assertFalse(type, mayShow(type, pushOn = false, prefs = all, fg = false))
        }
    }

    @Test fun theCatchUpSummaryNeverShowsWhileTheAppIsOpen() {
        assertFalse(mayShow("summary", true, all, true))
        assertTrue(mayShow("summary", true, all, false))
        assertFalse(mayShow("summary", true, none, false))
    }
}
