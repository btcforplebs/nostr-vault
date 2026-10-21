package com.nostrvault.ui.components

import com.nostrvault.data.model.TrustMap
import org.junit.Assert.assertEquals
import org.junit.Test

/** My Web's words, as iOS `MyWebDashboardView` says them. */
class MyWebWordsTest {
    @Test fun headlineGroupsThousands() {
        assertEquals("16,240 people", MyWebWords.headline(16_240))
    }

    @Test fun closeAndFurtherOutNameTheVouchLine() {
        assertEquals("Followed by 10+ people you follow", MyWebWords.layerDetail(TrustMap.Layer.CLOSE, true))
        assertEquals("Followed by fewer than 10 people you follow", MyWebWords.layerDetail(TrustMap.Layer.FURTHER_OUT, true))
    }

    @Test fun furtherOutWithoutVouchesHasNoLine() {
        assertEquals("Followed by people you follow", MyWebWords.layerDetail(TrustMap.Layer.FURTHER_OUT, false))
    }

    @Test fun followsBackOutOfYourFollows() {
        assertEquals("214 of the 1,032 people you follow", MyWebWords.followsBackDetail(214, 1_032, checking = false))
    }

    @Test fun followsBackWhileChecking() {
        assertEquals("Checking who follows you…", MyWebWords.followsBackDetail(null, 1_032, checking = true))
    }

    @Test fun followsBackWithNoLedger() {
        assertEquals("Your vault hasn't seen your followers yet", MyWebWords.followsBackDetail(null, 1_032, checking = false))
    }

    @Test fun followsBackWithNoFollowsSaysNoCount() {
        assertEquals("Your vault hasn't seen your followers yet", MyWebWords.followsBackDetail(0, 0, checking = false))
    }

    @Test fun rebuiltLine() {
        assertEquals("Rebuilding now…", MyWebWords.rebuilt(true, "3 hours ago"))
        assertEquals("Your vault rebuilds it once a day", MyWebWords.rebuilt(false, null))
        assertEquals("Last rebuilt 3 hours ago. Your vault rebuilds it once a day", MyWebWords.rebuilt(false, "3 hours ago"))
    }

    @Test fun unknownCountIsADash() {
        assertEquals("–", MyWebWords.count(null))
        assertEquals("0", MyWebWords.count(0))
    }
}
