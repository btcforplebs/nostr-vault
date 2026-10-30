package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The sweep sends the whole balance and cannot be undone, so the address
 * check is the only thing between a bad paste and lost funds. Vectors from
 * BIP173, BIP350 and BIP86. Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/BitcoinAddressTests.swift.
 */
class BitcoinAddressTest {
    private val taproot = "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr"

    @Test fun acceptsEveryMainnetTypeTheSweepCanPay() {
        assertEquals(BitcoinAddress.Kind.P2PKH, BitcoinAddress.mainnetKind("1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"))
        assertEquals(BitcoinAddress.Kind.P2SH, BitcoinAddress.mainnetKind("3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy"))
        assertEquals(BitcoinAddress.Kind.P2WPKH, BitcoinAddress.mainnetKind("BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4"))
        assertEquals(BitcoinAddress.Kind.P2WSH, BitcoinAddress.mainnetKind("bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3"))
        assertEquals(BitcoinAddress.Kind.P2TR, BitcoinAddress.mainnetKind(taproot))
    }

    @Test fun normalizedTrimsAPastedNewline() {
        assertEquals(taproot, BitcoinAddress.normalizedMainnet("  $taproot\n"))
    }

    /** One wrong character: the old gate (non-empty text) let each through. */
    @Test fun rejectsAOneCharacterTypo() {
        assertNull(BitcoinAddress.mainnetKind("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5"))
        assertNull(BitcoinAddress.mainnetKind("1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN3"))
        assertNull(BitcoinAddress.mainnetKind("bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcs"))
    }

    @Test fun rejectsATruncatedPaste() {
        assertNull(BitcoinAddress.mainnetKind("bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxq"))
        assertNull(BitcoinAddress.mainnetKind("1BvBMSEYstWetqTFn5Au4m4GFg7x"))
        assertNull(BitcoinAddress.normalizedMainnet(""))
        assertNull(BitcoinAddress.normalizedMainnet("   "))
    }

    @Test fun rejectsOtherNetworks() {
        assertNull(BitcoinAddress.mainnetKind("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"))
        assertNull(BitcoinAddress.mainnetKind("mipcBbFg9gMiCh81Kj8tqqdgoZub1ZJRfn"))
        // BIP350 testnet taproot and a 2N… testnet P2SH.
        assertNull(BitcoinAddress.mainnetKind("tb1pqqqqp399et2xygdj5xreqhjjvcmzhxw4aywxecjdzew6hylgvsesf3hn0c"))
        assertNull(BitcoinAddress.mainnetKind("2MzQwSSnBHWHqSAqtTVQ6v47XtaisrJa1Vc"))
    }

    @Test fun rejectsMixedCase() {
        assertNull(BitcoinAddress.mainnetKind("bc1qW508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"))
    }

    /** Taproot under the old bech32 checksum is the BIP350 trap; v2+ is not something the sweep can pay. */
    @Test fun rejectsWrongChecksumVariantAndUnknownVersions() {
        assertEquals(BitcoinAddress.Kind.P2TR, BitcoinAddress.mainnetKind("bc1pqqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0sg5tmnz"))
        assertNull(BitcoinAddress.mainnetKind("bc1pqqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0sagmhkq"))
        assertNull(BitcoinAddress.mainnetKind("bc1zqqqqqqqqqqqqqqqqqqqqqqqqqqr3t3q4"))
    }

    @Test fun rejectsNonAddressText() {
        assertNull(BitcoinAddress.mainnetKind("npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"))
        assertNull(BitcoinAddress.mainnetKind("bitcoin:$taproot"))
        assertNull(BitcoinAddress.mainnetKind("0OIl000000000000000000000000"))
    }
}
