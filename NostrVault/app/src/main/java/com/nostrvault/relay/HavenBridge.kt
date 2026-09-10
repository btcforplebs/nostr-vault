package com.nostrvault.relay

import android.system.Os
import android.util.Log

/**
 * JNI bridge to the Haven Go relay shared library (libhaven.so).
 *
 * NOTE: "Haven" is the Go relay binary name — acceptable per branding rules.
 * All user-facing references use "Nostr Vault".
 *
 * The Go relay runs in-process via c-shared build mode. On iOS/macOS this
 * is done via a subprocess + C archive; on Android we load a .so and call
 * exported C functions through JNI.
 */
object HavenBridge {

    private const val TAG = "HavenBridge"

    /** Tracks whether the native library has been loaded successfully. */
    @Volatile
    var isLoaded: Boolean = false
        private set

    init {
        try {
            // Set GODEBUG before loading libhaven.so so the Go runtime reads it
            // during initialization (dlopen time). asyncpreemptoff=1 disables
            // SIGURG-based goroutine preemption which conflicts with the JVM's
            // signal handling on Android and causes heap corruption
            // ("s.allocCount != s.nelems", "bad pointer in Go heap").
            // cgocheck=0 disables the CGO pointer validity checks that can
            // misfire when Go heap objects contain mmap'd region boundaries.
            Os.setenv("GODEBUG", "asyncpreemptoff=1,cgocheck=0,madvdontneed=1", true)
            // Cap Go heap to 192 MiB and collect more aggressively (default GOGC=100).
            // Without these, BadgerDB mmap + Go GC + JVM heap exceed the ~3-4 GB
            // available on typical Android devices, triggering the LMK.
            // Budget: ~100-130 MiB BadgerDB (5 DBs × ~20-26 MiB) + ~60 MiB headroom.
            Os.setenv("GOMEMLIMIT", "192MiB", true)
            Os.setenv("GOGC", "50", true)
            System.loadLibrary("haven")
            System.loadLibrary("nostrvault-jni")
            isLoaded = true
            Log.i(TAG, "libhaven.so + libnostrvault-jni.so loaded successfully")
        } catch (e: UnsatisfiedLinkError) {
            isLoaded = false
            Log.e(TAG, "Failed to load native libraries: ${e.message}")
        }
    }

    // -----------------------------------------------------------------------
    // Relay lifecycle
    // -----------------------------------------------------------------------

    /**
     * Set an environment variable before starting the relay.
     * Maps to Go: SetHavenEnvC(key, value)
     */
    external fun setEnv(key: String, value: String)

    /**
     * Start the relay. If [importMode] is true, runs a one-shot import
     * instead of the persistent relay server.
     * Maps to Go: StartRelayC(importMode)
     */
    external fun startRelay(importMode: Boolean)

    /**
     * Stop the relay and close all databases.
     * Maps to Go: StopRelayC()
     */
    external fun stopRelay()

    /**
     * Trigger an immediate inbox + owner catch-up pull in the running relay,
     * fetching newly tagged events (replies, reactions, zaps, reposts, mentions,
     * DMs) and the owner's own notes from external relays into the local DBs.
     * Non-blocking and safe to call when the relay is not running.
     * Maps to Go: RequestRelaySyncC()
     */
    external fun requestRelaySync()

    // -----------------------------------------------------------------------
    // Database operations
    // -----------------------------------------------------------------------

    /**
     * Export all relay databases to a zip file.
     * Returns 0 on success, 1 on failure.
     */
    external fun backupDatabase(outputPath: String): Int

    /**
     * Import relay databases from a zip file.
     * Returns 0 on success, 1 on failure.
     */
    external fun restoreDatabase(inputPath: String): Int

    /** Backup databases to configured cloud provider. */
    external fun backupToCloud(): Int

    /** Restore databases from configured cloud provider. */
    external fun restoreFromCloud(): Int

    /** Zip a directory to a file. */
    external fun zipDirectory(dirPath: String, zipPath: String): Int

    /** Unzip a file to a directory. */
    external fun unzipDirectory(zipPath: String, destPath: String): Int

    // -----------------------------------------------------------------------
    // Cryptographic operations
    // -----------------------------------------------------------------------

    /** Sign a Nostr event JSON with the given secret key hex. Returns signed event JSON. */
    external fun signEvent(eventJson: String, secretKeyHex: String): String?

    /**
     * Mine a PoW nonce and sign the event.
     * Falls back to signing without PoW if maxAttempts is exhausted.
     */
    external fun mineAndSignEvent(
        eventJson: String,
        secretKeyHex: String,
        difficulty: Int,
        maxAttempts: Int,
    ): String?

    /** Generate a new Nostr keypair. Returns "secretKeyHex:publicKeyHex". */
    external fun generateKeyPair(): String?

    /** Derive the public key hex from a secret key hex. */
    external fun getPublicKey(secretKeyHex: String): String?

    // -----------------------------------------------------------------------
    // NIP-04 encryption (legacy AES-256-CBC)
    // -----------------------------------------------------------------------

    external fun encryptNIP04(plaintext: String, pubkey: String, privkey: String): String?
    external fun decryptNIP04(ciphertext: String, pubkey: String, privkey: String): String?

    // -----------------------------------------------------------------------
    // NIP-44 encryption (ChaCha20-Poly1305)
    // -----------------------------------------------------------------------

    external fun encryptNIP44(plaintext: String, pubkey: String, privkey: String): String?
    external fun decryptNIP44(ciphertext: String, pubkey: String, privkey: String): String?

    // -----------------------------------------------------------------------
    // NIP-49 key encryption (scrypt + XChaCha20-Poly1305)
    // -----------------------------------------------------------------------

    /** Encrypt an nsec (hex) with a password. Returns ncryptsec bech32 string. */
    external fun encryptNIP49(nsecHex: String, password: String): String?

    /** Decrypt an ncryptsec bech32 string with a password. Returns nsec hex. */
    external fun decryptNIP49(ncryptsec: String, password: String): String?

    // -----------------------------------------------------------------------
    // Bitcoin / Taproot
    // -----------------------------------------------------------------------

    /** Derive a P2TR (taproot) address from a hex public key. */
    external fun deriveTaprootAddress(hexPubKey: String): String?

    /** Fetch current fee estimates from mempool.space. Returns JSON. */
    external fun fetchFeeEstimates(): String?

    /**
     * Sweep all UTXOs from the Nostr-derived taproot address to [destAddr].
     * Returns JSON: {"txid":"...","amount":...,"fee":...} or {"error":"..."}.
     */
    external fun sweepToAddress(
        nsecHex: String,
        destAddr: String,
        feeRateSatsPerVB: Int,
    ): String?

    // -----------------------------------------------------------------------
    // NIP-46 Remote Signer
    // -----------------------------------------------------------------------

    /** Connect to a NIP-46 bunker. Returns the signer's public key hex, or null on failure. */
    external fun nip46Connect(clientSecretKey: String, bunkerUrl: String): String?

    /** Disconnect from the NIP-46 bunker. */
    external fun nip46Disconnect()

    /** Sign an event via the remote signer. Returns signed event JSON. */
    external fun nip46SignEvent(eventJson: String): String?

    /** Get the signer's public key. */
    external fun nip46GetPublicKey(): String?

    /** Encrypt via NIP-44 through the remote signer. */
    external fun nip46NIP44Encrypt(targetPubkey: String, plaintext: String): String?

    /** Decrypt via NIP-44 through the remote signer. */
    external fun nip46NIP44Decrypt(targetPubkey: String, ciphertext: String): String?

    /** Encrypt via NIP-04 through the remote signer. */
    external fun nip46NIP04Encrypt(targetPubkey: String, plaintext: String): String?

    /** Decrypt via NIP-04 through the remote signer. */
    external fun nip46NIP04Decrypt(targetPubkey: String, ciphertext: String): String?

    /** Ping the remote signer. Returns 0 on success, 1 on failure. */
    external fun nip46Ping(): Int

    /** Get pending auth URL from the NIP-46 session (consumed on read). */
    external fun nip46GetPendingAuthUrl(): String?

    // -----------------------------------------------------------------------
    // DVM
    // -----------------------------------------------------------------------

    /** Compute popular notes from the local relay. Returns JSON array. */
    external fun computePopularNotes(): String?

    /**
     * Poll the latest Go log message from the import process.
     * Returns the most recent log line, or null if nothing new.
     * Consumed on read (won't return the same message twice).
     */
    external fun getImportLog(): String?

    /**
     * Poll the next "🔔NOTIFY|..." marker line from the dedicated, non-lossy
     * notification queue. Returns one line per call (consumed on read), or null
     * when the queue is empty. Drained by [LogStore] to raise local notifications.
     */
    external fun getNotifyLog(): String?

    // -----------------------------------------------------------------------
    // Bech32 encoding/decoding (pure Kotlin — no JNI needed)
    // -----------------------------------------------------------------------

    private const val BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    private fun bech32Polymod(values: IntArray): Int {
        var chk = 1
        for (v in values) {
            val b = chk ushr 25
            chk = ((chk and 0x1FFFFFF) shl 5) xor v
            if (b and 1 != 0) chk = chk xor 0x3B6A57B2.toInt()
            if (b and 2 != 0) chk = chk xor 0x26508E6D
            if (b and 4 != 0) chk = chk xor 0x1EA119FA
            if (b and 8 != 0) chk = chk xor 0x3D4233DD.toInt()
            if (b and 16 != 0) chk = chk xor 0x2A1462B3
        }
        return chk
    }

    private fun bech32HRPExpand(hrp: String): IntArray {
        val ret = IntArray(hrp.length * 2 + 1)
        for (i in hrp.indices) {
            ret[i] = hrp[i].code ushr 5
            ret[i + hrp.length + 1] = hrp[i].code and 31
        }
        return ret
    }

    private fun convertBits8to5(data: ByteArray): ByteArray {
        var acc = 0
        var bits = 0
        val result = mutableListOf<Byte>()
        for (b in data) {
            acc = (acc shl 8) or (b.toInt() and 0xFF)
            bits += 8
            while (bits >= 5) {
                bits -= 5
                result.add(((acc ushr bits) and 31).toByte())
            }
        }
        if (bits > 0) {
            result.add(((acc shl (5 - bits)) and 31).toByte())
        }
        return result.toByteArray()
    }

    private fun convertBits5to8(data: ByteArray): ByteArray {
        var acc = 0
        var bits = 0
        val result = mutableListOf<Byte>()
        for (v in data) {
            acc = (acc shl 5) or (v.toInt() and 31)
            bits += 5
            while (bits >= 8) {
                bits -= 8
                result.add(((acc ushr bits) and 0xFF).toByte())
            }
        }
        return result.toByteArray()
    }

    private fun bech32Encode(hrp: String, payload: ByteArray): String {
        val data5 = convertBits8to5(payload)
        val expanded = bech32HRPExpand(hrp)
        val values = IntArray(expanded.size + data5.size + 6)
        expanded.copyInto(values)
        for (i in data5.indices) values[expanded.size + i] = data5[i].toInt()
        val polymod = bech32Polymod(values) xor 1
        val checksum = ByteArray(6) { ((polymod ushr (5 * (5 - it))) and 31).toByte() }
        val combined = data5 + checksum
        return buildString(hrp.length + 1 + combined.size) {
            append(hrp)
            append('1')
            for (b in combined) append(BECH32_CHARSET[b.toInt() and 31])
        }
    }

    private fun bech32Decode(bech: String): Pair<String, ByteArray>? {
        val lower = bech.lowercase()
        val pos = lower.lastIndexOf('1')
        if (pos < 1 || pos + 7 > lower.length) return null
        val hrp = lower.substring(0, pos)
        val dataStr = lower.substring(pos + 1)
        val data5 = ByteArray(dataStr.length)
        for (i in dataStr.indices) {
            val idx = BECH32_CHARSET.indexOf(dataStr[i])
            if (idx < 0) return null
            data5[i] = idx.toByte()
        }
        val expanded = bech32HRPExpand(hrp)
        val values = IntArray(expanded.size + data5.size)
        expanded.copyInto(values)
        for (i in data5.indices) values[expanded.size + i] = data5[i].toInt()
        if (bech32Polymod(values) != 1) return null
        val payload = convertBits5to8(data5.copyOfRange(0, data5.size - 6))
        return Pair(hrp, payload)
    }

    private fun ByteArray.toHex(): String =
        joinToString("") { "%02x".format(it) }

    private fun hexToByteArray(hex: String): ByteArray? {
        if (hex.length % 2 != 0) return null
        return try {
            ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        } catch (_: NumberFormatException) { null }
    }

    /** Decode an npub bech32 string to a hex public key. */
    fun decodeNpub(npub: String): String? {
        val (hrp, payload) = bech32Decode(npub) ?: return null
        if (hrp != "npub" || payload.size != 32) return null
        return payload.toHex()
    }

    /** Encode a hex public key to an npub bech32 string. */
    fun encodeNpub(hexPubkey: String): String? {
        val bytes = hexToByteArray(hexPubkey) ?: return null
        if (bytes.size != 32) return null
        return bech32Encode("npub", bytes)
    }

    /** Decode an nsec bech32 string to a hex secret key. */
    fun decodeNsec(nsec: String): String? {
        val (hrp, payload) = bech32Decode(nsec) ?: return null
        if (hrp != "nsec" || payload.size != 32) return null
        return payload.toHex()
    }

    /** Encode a hex secret key to an nsec bech32 string. */
    fun encodeNsec(hexSeckey: String): String? {
        val bytes = hexToByteArray(hexSeckey) ?: return null
        if (bytes.size != 32) return null
        return bech32Encode("nsec", bytes)
    }

    /** Decode an nprofile bech32 string. Returns JSON: {"pubkey":"...","relays":[...]} */
    fun decodeNprofile(nprofile: String): String? {
        val (hrp, payload) = bech32Decode(nprofile) ?: return null
        if (hrp != "nprofile") return null
        var pubkey: String? = null
        val relays = mutableListOf<String>()
        var i = 0
        while (i + 2 <= payload.size) {
            val type = payload[i].toInt() and 0xFF
            val length = payload[i + 1].toInt() and 0xFF
            i += 2
            if (i + length > payload.size) break
            val value = payload.copyOfRange(i, i + length)
            when (type) {
                0 -> pubkey = value.toHex()
                1 -> relays.add(String(value, Charsets.UTF_8))
            }
            i += length
        }
        if (pubkey == null) return null
        val relaysJson = relays.joinToString(",") { "\"${it.replace("\\", "\\\\").replace("\"", "\\\"")}\"" }
        return """{"pubkey":"$pubkey","relays":[$relaysJson]}"""
    }

    /** Decode a note1 bech32 string to a hex event ID. */
    fun decodeNote(note1: String): String? {
        val (hrp, payload) = bech32Decode(note1) ?: return null
        if (hrp != "note" || payload.size != 32) return null
        return payload.toHex()
    }

    /** Encode a hex event ID to a note1 bech32 string. */
    fun hexToNote1(hexEventId: String): String? {
        val bytes = hexToByteArray(hexEventId) ?: return null
        if (bytes.size != 32) return null
        return bech32Encode("note", bytes)
    }

    /**
     * Encode an event reference to an nevent1 bech32 string (NIP-19 TLV).
     * Mirrors iOS FeedNote.nevent: type 0 (event id), type 2 (author pubkey),
     * type 3 (kind, big-endian UInt32). No relay hints.
     */
    fun encodeNevent(hexEventId: String, hexPubkey: String, kind: Int): String? {
        val idBytes = hexToByteArray(hexEventId) ?: return null
        if (idBytes.size != 32) return null
        val pubBytes = hexToByteArray(hexPubkey) ?: return null
        if (pubBytes.size != 32) return null
        val tlv = mutableListOf<Byte>()
        fun appendTLV(type: Int, value: ByteArray) {
            tlv.add(type.toByte())
            tlv.add(value.size.toByte())
            value.forEach { tlv.add(it) }
        }
        appendTLV(0, idBytes)
        appendTLV(2, pubBytes)
        appendTLV(3, byteArrayOf(
            ((kind ushr 24) and 0xFF).toByte(),
            ((kind ushr 16) and 0xFF).toByte(),
            ((kind ushr 8) and 0xFF).toByte(),
            (kind and 0xFF).toByte(),
        ))
        return bech32Encode("nevent", tlv.toByteArray())
    }

    /** Decode an nevent1 bech32 string. Returns the hex event ID (type 0 TLV). */
    fun decodeNevent(nevent1: String): String? {
        val (hrp, payload) = bech32Decode(nevent1) ?: return null
        if (hrp != "nevent") return null
        var i = 0
        while (i + 2 <= payload.size) {
            val type = payload[i].toInt() and 0xFF
            val length = payload[i + 1].toInt() and 0xFF
            i += 2
            if (i + length > payload.size) break
            if (type == 0 && length == 32) {
                return payload.copyOfRange(i, i + length).toHex()
            }
            i += length
        }
        return null
    }

    // -----------------------------------------------------------------------
    // Kotlin convenience aliases
    // -----------------------------------------------------------------------

    /** Alias for generateKeyPair() matching the naming used by setup screens. */
    fun generateKeypair(): String? = generateKeyPair()

    /** Convert nsec bech32 to hex secret key. */
    fun nsecToHex(nsec: String): String? = decodeNsec(nsec)

    /** Convert hex public key to npub bech32. */
    fun hexToNpub(hex: String): String? = encodeNpub(hex)
}
