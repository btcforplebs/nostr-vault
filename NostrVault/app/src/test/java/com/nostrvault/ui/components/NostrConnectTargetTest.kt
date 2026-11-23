package com.nostrvault.ui.components

import com.google.zxing.BinaryBitmap
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import com.nostrvault.service.NIP46Service
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** "Show a code for another device" on the sign-in screens. */
class NostrConnectTargetTest {
    /** The other-device code must stay on screen: no jump to Amber here. */
    @Test
    fun onlyThisDeviceOpensTheSigner() {
        assertTrue(NostrConnectTarget.THIS_DEVICE.opensSigner)
        assertFalse(NostrConnectTarget.OTHER_DEVICE.opensSigner)
        assertTrue(NostrConnectTarget.OTHER_DEVICE.waitingText.contains("other device"))
    }

    /** The code on screen reads back as exactly the request we wait on. */
    @Test
    fun qrReadsBackAsTheRequest() {
        val uri = NIP46Service.nostrConnectUri("c".repeat(64), "0123456789abcdef0123456789abcdef",
            listOf("wss://relay.powr.build", "wss://relay.damus.io"))
        val m = requireNotNull(nostrConnectQrMatrix(uri))
        val pad = 40
        val w = m.width + 2 * pad
        val h = m.height + 2 * pad
        val px = IntArray(w * h) { 0xFFFFFFFF.toInt() }
        for (y in 0 until m.height) for (x in 0 until m.width) {
            if (m[x, y]) px[(y + pad) * w + x + pad] = 0xFF000000.toInt()
        }
        val text = QRCodeReader().decode(BinaryBitmap(HybridBinarizer(RGBLuminanceSource(w, h, px)))).text
        assertEquals(uri, text)
    }
}
