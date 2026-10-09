package com.nostrvault.data.local

import org.junit.Assert.assertEquals
import org.junit.Test

/** Setup used to store the keychain password with its arguments swapped. */
class CredentialStoreRepairTest {
    private val npub = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"

    @Test fun findsTheSwappedEntryAndItsPassword() {
        val entries = mapOf(
            "keychain-hunter22!" to npub,              // swapped: password in the key
            "keychain-$npub" to "already-right",        // correct entry
            "nsec-hex-abc" to "def",
            "keychain-" to npub,                        // no password to recover
        )
        assertEquals(listOf(Triple("keychain-hunter22!", npub, "hunter22!")), CredentialStore.swappedKeychainEntries(entries))
    }

    @Test fun leavesCorrectEntriesAlone() {
        assertEquals(emptyList<Any>(), CredentialStore.swappedKeychainEntries(mapOf("keychain-$npub" to "pw")))
    }
}
