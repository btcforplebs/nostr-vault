package com.nostrvault.ui.screens

import java.security.MessageDigest

/**
 * Mainnet address check for the Bitcoin sweep, which sends the whole balance
 * and cannot be undone. A truncated paste or a one-character slip must not
 * reach the broadcast.
 *
 * Accepts what the Go sweep (haven-go/bitcoin.go, btcutil with MainNetParams)
 * can pay: P2PKH (1…), P2SH (3…), segwit v0 (bc1q…, 20 or 32 bytes, bech32)
 * and taproot (bc1p…, 32 bytes, bech32m). Testnet and regtest addresses,
 * later witness versions and anything failing its checksum are rejected.
 * iOS: BitcoinAddress.swift.
 */
object BitcoinAddress {

    enum class Kind { P2PKH, P2SH, P2WPKH, P2WSH, P2TR }

    /**
     * The address with surrounding whitespace removed, if it is a valid
     * mainnet address; null otherwise. Send this, not the raw field text.
     */
    fun normalizedMainnet(input: String): String? {
        val trimmed = input.trim()
        return if (mainnetKind(trimmed) == null) null else trimmed
    }

    fun mainnetKind(address: String): Kind? =
        if (address.lowercase().startsWith("bc1")) segwitKind(address) else base58Kind(address)

    // ── Segwit (BIP173 / BIP350) ─────────────────────────────────────

    private const val CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    private const val BECH32_CONST = 1
    private const val BECH32M_CONST = 0x2bc830a3

    private fun segwitKind(address: String): Kind? {
        if (address != address.lowercase() && address != address.uppercase()) return null
        if (address.length > 90) return null
        val lower = address.lowercase()
        val separator = lower.lastIndexOf('1')
        if (separator < 0 || lower.substring(0, separator) != "bc") return null

        val values = ArrayList<Int>()
        for (character in lower.substring(separator + 1)) {
            val index = CHARSET.indexOf(character)
            if (index < 0) return null
            values.add(index)
        }
        if (values.size < 7) return null

        val version = values[0]
        val check = polymod(hrpExpand("bc") + values)
        // v0 uses bech32; v1+ uses bech32m. The wrong one is a bad address.
        if (check != (if (version == 0) BECH32_CONST else BECH32M_CONST)) return null
        val program = fiveToEight(values.subList(1, values.size - 6)) ?: return null

        return when {
            version == 0 && program.size == 20 -> Kind.P2WPKH
            version == 0 && program.size == 32 -> Kind.P2WSH
            version == 1 && program.size == 32 -> Kind.P2TR
            else -> null
        }
    }

    private fun hrpExpand(hrp: String): List<Int> {
        val codes = hrp.map { it.code }
        return codes.map { it shr 5 } + 0 + codes.map { it and 31 }
    }

    private fun polymod(values: List<Int>): Int {
        val generator = intArrayOf(0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)
        var check = 1
        for (value in values) {
            val top = check ushr 25
            check = ((check and 0x1ffffff) shl 5) xor value
            for (index in 0 until 5) if ((top shr index) and 1 == 1) check = check xor generator[index]
        }
        return check
    }

    /** 5-bit groups to bytes; leftover bits must be fewer than 5 and zero. */
    private fun fiveToEight(values: List<Int>): ByteArray? {
        var accumulator = 0
        var bits = 0
        val bytes = ArrayList<Byte>()
        for (value in values) {
            accumulator = ((accumulator shl 5) or value) and 0xfff
            bits += 5
            if (bits >= 8) {
                bits -= 8
                bytes.add(((accumulator shr bits) and 0xff).toByte())
            }
        }
        if (bits >= 5 || (accumulator shl (8 - bits)) and 0xff != 0) return null
        return bytes.toByteArray()
    }

    // ── Base58Check ──────────────────────────────────────────────────

    private const val BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

    private fun base58Kind(address: String): Kind? {
        if (address.length !in 25..35) return null

        // Big-endian base-58 to base-256, one digit at a time.
        val bytes = ArrayList<Int>()
        for (character in address) {
            val digit = BASE58_ALPHABET.indexOf(character)
            if (digit < 0) return null
            var carry = digit
            for (index in bytes.indices.reversed()) {
                carry += bytes[index] * 58
                bytes[index] = carry and 0xff
                carry = carry shr 8
            }
            while (carry > 0) {
                bytes.add(0, carry and 0xff)
                carry = carry shr 8
            }
        }
        val leadingZeros = address.takeWhile { it == '1' }.length
        val full = List(leadingZeros) { 0 } + bytes.dropWhile { it == 0 }

        if (full.size != 25) return null
        val body = ByteArray(21) { full[it].toByte() }
        val sha = MessageDigest.getInstance("SHA-256")
        val checksum = sha.digest(sha.digest(body)).take(4).map { it.toInt() and 0xff }
        if (checksum != full.subList(21, 25)) return null

        return when (full[0]) {
            0x00 -> Kind.P2PKH
            0x05 -> Kind.P2SH
            else -> null
        }
    }
}
