package com.nostrvault.ui.screens.profile

import org.junit.Assert.assertEquals
import org.junit.Test

/** The profile grids' column counts match iOS on phones and tablets. */
class ProfileGridTest {
    @Test
    fun mediaIsThreeOnAPhoneAndMoreOnATablet() {
        assertEquals(3, ProfileGrid.mediaColumns(360f))
        assertEquals(3, ProfileGrid.mediaColumns(411f))
        assertEquals(4, ProfileGrid.mediaColumns(800f))
        assertEquals(6, ProfileGrid.mediaColumns(1280f))
        assertEquals(6, ProfileGrid.mediaColumns(2000f))
    }

    @Test
    fun unmeasuredWidthKeepsThePhoneCount() {
        assertEquals(3, ProfileGrid.columnCount(0f, 180f, 6f, 3, 6))
    }

    @Test
    fun divinesAndShopFitTheirMinimumWidths() {
        // 411 - 32 = 379: three 110s with gaps (338) fit, four (452) do not.
        assertEquals(3, ProfileGrid.divineColumns(411f))
        assertEquals(2, ProfileGrid.shopColumns(411f))
        assertEquals(1, ProfileGrid.shopColumns(300f))
        assertEquals(5, ProfileGrid.shopColumns(900f))
    }

    @Test
    fun middleEllipsisKeepsBothEnds() {
        assertEquals("short@wallet.com", middleEllipsis("short@wallet.com"))
        val cut = middleEllipsis("averyveryverylongname@some.long.wallet.example")
        assertEquals(30, cut.length)
        assertEquals(true, cut.startsWith("averyveryveryl"))
        assertEquals(true, cut.endsWith("wallet.example"))
    }
}
