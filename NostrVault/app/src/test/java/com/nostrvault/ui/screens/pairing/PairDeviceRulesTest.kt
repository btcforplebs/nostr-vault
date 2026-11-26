package com.nostrvault.ui.screens.pairing

import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.MeshPairing
import com.nostrvault.fips.MeshPairingJoiner
import com.nostrvault.fips.MeshPairingSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PairDeviceRulesTest {
    /** Bug hunt 2026-11-05 #8: "Already linked" sent no hello, so the side that removed this phone never re-added it. */
    @Test
    fun `an already linked device sends the hello again`() {
        assertEquals(PairDeviceRules.AfterScan.JoinAgain, PairDeviceRules.afterScanFirst(MeshPairing.RoleCheck.AlreadyLinked))
        assertEquals(PairDeviceRules.AfterScan.Confirm, PairDeviceRules.afterScanFirst(MeshPairing.RoleCheck.Add))
        assertEquals(
            PairDeviceRules.AfterScan.Refuse(MeshPairing.otherRoleText(DeviceRole.MAC)),
            PairDeviceRules.afterScanFirst(MeshPairing.RoleCheck.RefuseOtherRole(DeviceRole.MAC)),
        )
    }

    /** Bug hunt 2026-11-05 (lower): another account on this phone was told it "belongs to another account". */
    @Test
    fun `another account on this phone is told to switch`() {
        assertEquals("This is Sam's device. Switch to Sam first.", PairDeviceRules.helloRefusalText("switchTo", "Sam"))
        assertEquals(MeshPairing.OTHER_OWNER_TEXT, PairDeviceRules.helloRefusalText("otherOwner", null))
        assertEquals(MeshPairing.OTHER_OWNER_TEXT, PairDeviceRules.helloRefusalText("switchTo", null))
    }

    // Random bytes with a good checksum: no one's key (generated for this test).
    private val box = "npub1mzurdfw86hd5y8rhy0n4g45tq4wwckgmatwuw8n54lc0g80k7a0s9g40k8"
    private val own = "npub1y5lv05ucrenq8q9nzvh4ghjz8wxvgv7ncf9fj62qd44eynah7nrskewhcc"

    /** Logen 2026-11-08: Paste instead takes the other device's code, the same as scanning it. */
    @Test
    fun `a pasted pairing code goes in like a scan`() {
        assertEquals(PairDeviceRules.Paste.Code("nvpair:v1?m=x"), PairDeviceRules.paste("  nvpair:v1?m=x \n", own))
        assertEquals(PairDeviceRules.Paste.Code("NVPAIR:v1?m=x"), PairDeviceRules.paste("NVPAIR:v1?m=x", own))
    }

    /** A Linux box or the browser relay page shows only its mesh address: that is the one-way add. */
    @Test
    fun `a pasted mesh address opens the one-way add`() {
        assertEquals(PairDeviceRules.Paste.Address(box), PairDeviceRules.paste(box, own))
        assertEquals(PairDeviceRules.Paste.Address(box), PairDeviceRules.paste("nostr:$box", own))
        assertEquals(PairDeviceRules.Paste.Address(box), PairDeviceRules.paste("fipsmesh://$box/", null))
    }

    @Test
    fun `a typo, junk or this phone's own address is refused`() {
        val typo = box.dropLast(1) + if (box.last() == 'q') 'p' else 'q'
        assertEquals(PairDeviceRules.Paste.Refuse(PairDeviceRules.NOT_A_CODE_TEXT), PairDeviceRules.paste(typo, own))
        assertEquals(PairDeviceRules.Paste.Refuse(PairDeviceRules.NOT_A_CODE_TEXT), PairDeviceRules.paste("hello", own))
        assertEquals(PairDeviceRules.Paste.Refuse(PairDeviceRules.OWN_ADDRESS_TEXT), PairDeviceRules.paste(own, own))
    }

    /**
     * Logen 2026-11-26 ("fix the they match issues"): when this phone scans the Mac and the Mac taps "They match.
     * Accept", the words must already be under the phone's code, and an early "They match" tap here links on A's
     * words ack with no second screen.
     */
    @Test
    fun `the words under this phone's code match the Mac's and an early tap links`() {
        val aHex = MeshPairing.npubHex(box)!!
        val bHex = MeshPairing.npubHex(own)!!
        val now = 1_800_000_000L
        val aSecret = MeshPairing.newSecret()
        val qrA = MeshPairing.build(box, "Mac", DeviceRole.MAC, own, MeshPairing.Code.Secret(aSecret), listOf(own))
        val a = (MeshPairing.parse(qrA, own) as MeshPairing.Parsed.Ok).payload

        // B (this phone) shows its code with the words; A (the Mac) gets the hello and accepts with the words.
        val words = PairDeviceRules.joinWords(a, bHex)
        assertEquals(4, words.size)
        val session = MeshPairingSession(aSecret, now, aHex, own, listOf(own), matchAnyAccount = true)
        val hello = MeshPairing.helloJson(aSecret, "Moto", DeviceRole.PHONE, own, now, listOf(own))
        assertTrue(session.receiveHello(bHex, hello, now) is MeshPairingSession.Outcome.Camera)
        assertTrue(session.acceptWithoutScan(now + 5) is MeshPairingSession.Outcome.Confirm)
        assertEquals(MeshPairing.checkWords(aHex, bHex, aSecret), words)

        // The early tap waits for the ack, then the words ack links at once.
        val joiner = MeshPairingJoiner.start(a, bHex, MeshPairing.newSecret(), now)!!
        assertEquals(MeshPairingJoiner.Outcome.WaitAck, joiner.confirmWords(now + 3))
        assertEquals(MeshPairingJoiner.Outcome.Linked, joiner.receiveAck(aHex, session.ack!!, now + 6))
    }
}
