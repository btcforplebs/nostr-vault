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

    /** Quiet zone as drawn: the matrix's own white edge, scaled to the
     *  on-screen size, plus the card's white border, in modules. The QR spec
     *  asks for 4 (Tron, #2477). Short requests are the tight case: fewer,
     *  bigger modules make the fixed dp border fewer modules wide. The finder
     *  pattern's top edge is a dark run exactly 7 modules wide. */
    @Test
    fun quietZoneIsAtLeastFourModulesOnScreen() {
        val relaySets = listOf(
            listOf("wss://a.io"),
            listOf("wss://relay.powr.build"),
            listOf("wss://relay.powr.build", "wss://relay.damus.io"),
            listOf("wss://relay.powr.build", "wss://relay.damus.io", "wss://nos.lol", "wss://relay.primal.net"),
        )
        for (relays in relaySets) for (extra in 0..40 step 4) {
            val uri = NIP46Service.nostrConnectUri("c".repeat(64), "0123456789abcdef0123456789abcdef", relays) + "x".repeat(extra)
            val m = requireNotNull(nostrConnectQrMatrix(uri))
            val top = (0 until m.height).first { y -> (0 until m.width).any { m[it, y] } }
            val left = (0 until m.width).first { m[it, top] }
            val run = (left until m.width).takeWhile { m[it, top] }.count()
            val dpPerPx = NOSTR_CONNECT_QR_DP.toDouble() / m.width
            val moduleDp = run / 7.0 * dpPerPx
            val quietModules = (minOf(left, top) * dpPerPx + NOSTR_CONNECT_QR_BORDER_DP) / moduleDp
            assertTrue("quiet zone %.2f modules for a %d-char request".format(quietModules, uri.length), quietModules >= 4.0)
        }
    }
}
