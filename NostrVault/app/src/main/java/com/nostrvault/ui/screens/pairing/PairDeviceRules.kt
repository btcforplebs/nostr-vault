package com.nostrvault.ui.screens.pairing

import com.nostrvault.fips.MeshPairing

/** The pairing screen's choices that aren't the phase-0 session's, pure for the tests. */
internal object PairDeviceRules {

    sealed interface AfterScan {
        data class Refuse(val text: String) : AfterScan
        /** New to this phone: the person confirms the role first. */
        data object Confirm : AfterScan
        /**
         * Already here under that role: send the hello at once, with no new confirm, so the other side (which may
         * have removed this phone) can finish and add it again. Saying "Already linked" and stopping left it counting
         * down to "expired" (bug hunt 2026-11-05 #8).
         */
        data object JoinAgain : AfterScan
    }

    /** B, after reading A's code and passing the owner check. */
    fun afterScanFirst(role: MeshPairing.RoleCheck): AfterScan = when (role) {
        is MeshPairing.RoleCheck.RefuseOtherRole -> AfterScan.Refuse(MeshPairing.otherRoleText(role.role))
        MeshPairing.RoleCheck.AlreadyLinked -> AfterScan.JoinAgain
        MeshPairing.RoleCheck.Add -> AfterScan.Confirm
    }

    /**
     * A, a hello the owner check turned away. A device of another account on this phone is told to switch to it,
     * not that it "belongs to another account" (bug hunt 2026-11-05, lower).
     */
    fun helloRefusalText(why: String, switchToName: String?): String =
        if (why == "switchTo" && switchToName != null) MeshPairing.switchToText(switchToName) else MeshPairing.OTHER_OWNER_TEXT
}
