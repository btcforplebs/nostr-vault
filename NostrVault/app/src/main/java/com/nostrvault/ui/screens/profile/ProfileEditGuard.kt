package com.nostrvault.ui.screens.profile

/**
 * Who may save Edit Profile, and when the sheet may be swiped away. A kind 0
 * replaces the whole profile of whoever signs it, so on a phone with two
 * accounts a save signed by the wrong one overwrites that account's profile
 * (Logen, 2026-10-24).
 */
object ProfileEditGuard {
    /**
     * True only when [signer], the profile being edited and the account the
     * form was filled from are the same key. Anything else signs nothing.
     */
    fun maySign(signer: String, editedProfile: String, formAccount: String): Boolean {
        if (signer.isBlank()) return false
        return signer.equals(editedProfile, ignoreCase = true) && signer.equals(formAccount, ignoreCase = true)
    }

    /**
     * Swipe, Back and a tap outside close without saving, so they are held
     * while something changed (Save or Discard decides) or a photo uploads.
     */
    fun closesOnSwipe(hasChanges: Boolean, uploading: Boolean): Boolean = !hasChanges && !uploading
}
