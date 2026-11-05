package com.nostrvault.ui.screens.pairing

import com.nostrvault.fips.DeviceRole
import com.nostrvault.fips.MeshPairing
import org.junit.Assert.assertEquals
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
}
