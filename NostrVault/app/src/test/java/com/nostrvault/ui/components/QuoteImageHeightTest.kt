package com.nostrvault.ui.components

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Test

class QuoteImageHeightTest {
    @Test fun tallPhotoGets220() = assertEquals(220.dp, quoteImageMaxHeight(3f / 4f))
    @Test fun widePhotoGets180() = assertEquals(180.dp, quoteImageMaxHeight(16f / 9f))
    @Test fun squarePhotoGets180() = assertEquals(180.dp, quoteImageMaxHeight(1f))
    @Test fun unknownShapeGets180() = assertEquals(180.dp, quoteImageMaxHeight(null))
}
