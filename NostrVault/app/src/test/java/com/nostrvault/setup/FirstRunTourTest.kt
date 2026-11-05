package com.nostrvault.setup

import com.nostrvault.service.FirstRunImport
import org.junit.Assert.assertEquals
import org.junit.Test

/** The tour's line while the relay's `setup` job runs, in the words ImportTourStage maps to its stages. */
class FirstRunTourTest {
    @Test
    fun `setup job states map onto the tour's stages`() {
        assertEquals(1, ImportTourStage.from(FirstRunTour.statusLine(FirstRunImport.State.Starting), false).step)
        assertEquals(2, ImportTourStage.from(FirstRunTour.statusLine(FirstRunImport.State.Bringing(812)), false).step)
        assertEquals("Saving your notes…", ImportTourStage.from(FirstRunTour.statusLine(FirstRunImport.State.Bringing(0)), false).text)
        assertEquals(4, ImportTourStage.from(FirstRunTour.statusLine(FirstRunImport.State.In(partial = true, stored = 9)), true).step)
    }
}
