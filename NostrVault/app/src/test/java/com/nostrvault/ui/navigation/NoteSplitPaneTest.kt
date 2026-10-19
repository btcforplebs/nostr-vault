package com.nostrvault.ui.navigation

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Widths and picks of the tablet note pane (iOS NoteSplitMetrics / NoteSplitSelection). */
class NoteSplitPaneTest {
    @Test fun phonesAndNarrowPanesStayOneColumn() {
        assertNull(noteSplitListWidth(360.dp))
        assertNull(noteSplitListWidth(640.dp))
    }

    @Test fun listKeepsItsDefaultWidthWhereThereIsRoom() {
        assertEquals(380.dp, noteSplitListWidth(1000.dp))
        assertEquals(380.dp, noteSplitListWidth(1280.dp))
    }

    @Test fun listGivesWayOnlyToTheNoteColumnsFloor() {
        // 641..739: the note column never drops under 360dp.
        assertEquals(281.dp, noteSplitListWidth(641.dp))
        assertEquals(380.dp, noteSplitListWidth(740.dp))
    }

    @Test fun picksSurviveSaveAndRestore() {
        val note = NotePick.Note("abc:1")
        val article = NotePick.Article("def")
        assertEquals(note, NotePick.decode(NotePick.encode(note)))
        assertEquals(article, NotePick.decode(NotePick.encode(article)))
        assertNull(NotePick.decode(NotePick.encode(null)))
        assertNull(NotePick.decode("garbage"))
    }
}
