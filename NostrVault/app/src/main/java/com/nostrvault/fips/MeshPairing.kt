package com.nostrvault.fips

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.longOrNull
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/**
 * Two-scan device pairing: the QR codes, the hello and ack, and the checks. Pure: no I/O, no keys. The contract is
 * docs/MESH_PAIRING_CONTRACT.md; iOS MeshPairing.swift and the web (src/net/mesh-pairing.js) agree with it through
 * the fixtures in HavenApp/MediaLogicTests/Tests/MediaLogicTests/Fixtures/MeshPairing.
 */
object MeshPairing {
    const val HELLO_KIND = 21195
    /** Seconds A's code may open the camera after it is shown. */
    const val CODE_LIFETIME = 180L
    /** Seconds A has to scan B's code (or Accept) after the hello. */
    const val SCAN_WINDOW = 180L
    /** Seconds B waits for the ack after scanning A. */
    const val ACK_WINDOW = 360L
    /** A hello's own time must be this close to now. */
    const val HELLO_SKEW = 180L
    /** A device name, in Unicode code points. */
    const val NAME_MAX = 40

    /** The wire role (iOS MeshDeviceRole raw values); Android stores HOME_VAULT as "home_vault". */
    val WIRE_ROLES = listOf("phone" to DeviceRole.PHONE, "mac" to DeviceRole.MAC, "homeVault" to DeviceRole.HOME_VAULT, "browser" to DeviceRole.BROWSER)

    fun roleFromWire(s: String?): DeviceRole? = WIRE_ROLES.firstOrNull { it.first == s }?.second
    fun wire(role: DeviceRole): String = WIRE_ROLES.first { it.second == role }.first

    enum class Refusal { NotPairing, UnsupportedVersion, Malformed, BadAddress, UnknownRole, MissingOwner, BadCode, NameTooLong, OwnAddress;
        /** The fixtures' name: notPairing, badCode, … */
        val code: String get() = name.replaceFirstChar { it.lowercase() }
    }

    sealed interface Code {
        val value: String
        /** A's code: its one-time secret. */
        data class Secret(override val value: String) : Code
        /**
         * B's code: A's secret, echoed, and B's own fresh secret s_B. Only a device that read B's code knows s_B, so
         * the scan ack proves the scan (Tron, PR 1700).
         */
        data class Echo(override val value: String, val bSecret: String) : Code
    }

    data class Payload(
        val mesh: String,
        val meshHex: String,
        val name: String,
        val role: DeviceRole,
        val owner: String,
        val ownerHex: String,
        val code: Code,
        /**
         * `ah`: the other device's signing accounts, each as a tag salted with this code's secret ([accountTag]), so
         * a link works when the two share any account. Never npubs in plain text (Tron, PR 1809). Only A's code.
         */
        val accountTags: List<String> = emptyList(),
    )

    sealed interface Parsed {
        data class Ok(val payload: Payload) : Parsed
        data class Refused(val refusal: Refusal) : Parsed
    }

    // ---- The QR ----

    fun build(mesh: String, name: String, role: DeviceRole, owner: String, code: Code, accounts: List<String> = emptyList()): String {
        val q = mutableListOf("m=$mesh")
        val n = cleanName(name)
        if (n.isNotEmpty()) q += "n=${percentEncode(n)}"
        q += "r=${wire(role)}"
        q += "o=$owner"
        q += when (code) {
            is Code.Secret -> "s=${code.value}"
            is Code.Echo -> "e=${code.value}"
        }
        if (code is Code.Echo) q += "b=${code.bSecret}"
        if (code is Code.Secret) {
            val tags = wireAccounts(accounts, owner).mapNotNull { accountTag(it, code.value) }
            if (tags.isNotEmpty()) q += "ah=" + tags.joinToString(",")
        }
        return "nvpair:v1?" + q.joinToString("&")
    }

    /** The pairing code in [uri], or why it can't be used. [ownMesh] is this device's own mesh npub. */
    fun parse(uri: String, ownMesh: String?): Parsed {
        val u = uri.trim()
        if (u.length < 7 || !u.substring(0, 7).equals("nvpair:", ignoreCase = true)) return Parsed.Refused(Refusal.NotPairing)
        val rest = u.substring(7)
        val q = rest.indexOf('?')
        val version = if (q >= 0) rest.substring(0, q) else rest
        val query = if (q >= 0) rest.substring(q + 1) else ""
        if (version != "v1") return Parsed.Refused(Refusal.UnsupportedVersion)
        val fields = mutableMapOf<String, String>()
        if (query.isNotEmpty()) {
            for (part in query.split('&')) {
                val eq = part.indexOf('=')
                if (eq < 0) return Parsed.Refused(Refusal.Malformed)
                val key = part.substring(0, eq)
                val value = percentDecode(part.substring(eq + 1))
                if (key in fields || value == null) return Parsed.Refused(Refusal.Malformed)
                fields[key] = value
            }
        }
        val meshHex = npubHex(fields["m"]) ?: return Parsed.Refused(Refusal.BadAddress)
        val role = roleFromWire(fields["r"]) ?: return Parsed.Refused(Refusal.UnknownRole)
        val ownerHex = npubHex(fields["o"]) ?: return Parsed.Refused(Refusal.MissingOwner)
        // A's code has s and no b; B's has e and b.
        val s = fields["s"]
        val e = fields["e"]
        val b = fields["b"]
        if ((s == null) == (e == null) || (s == null) != (b != null)) return Parsed.Refused(Refusal.BadCode)
        val raw = s ?: e!!
        if (secretBytes(raw) == null || (b != null && secretBytes(b) == null)) return Parsed.Refused(Refusal.BadCode)
        val name = fields["n"].orEmpty().trim()
        if (name.codePointCount(0, name.length) > NAME_MAX) return Parsed.Refused(Refusal.NameTooLong)
        if (ownMesh != null && npubHex(ownMesh) == meshHex) return Parsed.Refused(Refusal.OwnAddress)
        return Parsed.Ok(
            Payload(
                mesh = npub(meshHex), meshHex = meshHex, name = name, role = role,
                owner = npub(ownerHex), ownerHex = ownerHex, code = if (s != null) Code.Secret(raw) else Code.Echo(raw, b!!),
                accountTags = if (s != null) readTags(fields["ah"].orEmpty()) else emptyList(),
            ),
        )
    }

    // ---- Owner and role ----

    sealed interface OwnerCheck {
        data object Ok : OwnerCheck
        /** Another account on this device: switch to it first. */
        data class SwitchTo(val npub: String) : OwnerCheck
        data object OtherOwner : OwnerCheck
    }

    /** [owner] against every account on this device, not only the active one. */
    fun ownerCheck(owner: String, active: String?, accounts: List<String>): OwnerCheck {
        val hex = npubHex(owner) ?: return OwnerCheck.OtherOwner
        if (active != null && npubHex(active) == hex) return OwnerCheck.Ok
        accounts.firstOrNull { npubHex(it) == hex }?.let { return OwnerCheck.SwitchTo(it) }
        return OwnerCheck.OtherOwner
    }

    /**
     * The link rule (Logen, 2026-11-06): two devices may link when they share any account, not only the active one.
     * [owner] and [theirs] are what the other device sent (`o` and `a`); [mine] is what this device pairs on.
     */
    fun sharesAccount(owner: String, theirs: List<String>, mine: List<String>): Boolean {
        val own = mine.mapNotNull(::npubHex).toSet()
        return (listOf(owner) + theirs).any { n -> npubHex(n)?.let(own::contains) == true }
    }

    /** The QR's rule: [owner] (`o`) is one of [mine], or one of [mine] makes a tag in [tags] (`ah`) with [secret]. */
    fun sharesAccount(owner: String, tags: List<String>, secret: String, mine: List<String>): Boolean {
        if (sharesAccount(owner, emptyList(), mine)) return true
        val theirs = tags.toSet()
        return mine.any { n -> accountTag(n, secret)?.let(theirs::contains) == true }
    }

    /**
     * One account in `ah`: the first [TAG_BYTES] bytes of SHA-256("nvpair-ah" ‖ s ‖ pubkey), hex. Salted per code,
     * so a photo of one code can only test a guessed npub against that code, never list the accounts.
     */
    fun accountTag(npub: String, secret: String): String? {
        val s = secretBytes(secret) ?: return null
        val key = npubHex(npub)?.let(::hexBytes)?.takeIf { it.size == 32 } ?: return null
        return sha256("nvpair-ah".toByteArray() + s + key).take(TAG_BYTES).joinToString("") { "%02x".format(it) }
    }

    const val TAG_BYTES = 8

    /** At most this many accounts travel in `a` or `ah` (a QR code has to stay scannable). */
    const val ACCOUNTS_MAX = 8

    /**
     * The accounts this device pairs on: [owner], plus every other account it can sign for ([canSign]: a stored key
     * or a signer). Look-only accounts are often someone else's public npub, so two people watching one npub must
     * not link (Tron, PR 1809).
     */
    fun signingAccounts(owner: String, all: List<String>, canSign: (String) -> Boolean): List<String> =
        all.filter { it == owner || canSign(it) }

    /** `a` as sent: npubs, without the owner (`o` carries it), no repeats. */
    private fun wireAccounts(accounts: List<String>, owner: String): List<String> {
        val seen = mutableSetOf(npubHex(owner).orEmpty())
        return accounts.mapNotNull { n -> npubHex(n)?.takeIf(seen::add)?.let(::npub) }.take(ACCOUNTS_MAX)
    }

    /** `ah` as read: only well-formed tags, no repeats; a bad entry is dropped, never a refusal. */
    private fun readTags(raw: String): List<String> {
        val seen = mutableSetOf<String>()
        return raw.split(',').filter { t -> t.length == TAG_BYTES * 2 && t.all { it in "0123456789abcdef" } && seen.add(t) }.take(ACCOUNTS_MAX)
    }

    /** `a` as read: only the entries that are npubs, no repeats. A bad entry is dropped: `a` is optional. */
    private fun readAccounts(raw: Any?): List<String> {
        val seen = mutableSetOf<String>()
        return (raw as? JsonArray).orEmpty().mapNotNull { npubHex(stringOf(it))?.takeIf(seen::add)?.let(::npub) }.take(ACCOUNTS_MAX)
    }

    sealed interface RoleCheck {
        data object Add : RoleCheck
        data object AlreadyLinked : RoleCheck
        /** Known under another role: never moved silently (Tron 1). */
        data class RefuseOtherRole(val role: DeviceRole) : RoleCheck
    }

    fun roleCheck(npub: String, role: DeviceRole, existing: List<Pair<String, DeviceRole>>): RoleCheck {
        val hex = npubHex(npub)
        val known = existing.firstOrNull { npubHex(it.first) == hex } ?: return RoleCheck.Add
        return if (known.second == role) RoleCheck.AlreadyLinked else RoleCheck.RefuseOtherRole(known.second)
    }

    // ---- Words people read ----

    /** The role confirm the person taps before anything is stored (Tron 1). [setup]: first-run "bring it over". */
    fun roleConfirmText(role: DeviceRole, name: String, setup: Boolean = false): String {
        val n = displayName(name)
        if (setup) return "Add $n as another of your devices: your vault copies between them."
        return when (role) {
            DeviceRole.MAC -> "Add $n as your Mac: your vault syncs to it and it keeps a full copy."
            DeviceRole.HOME_VAULT -> "Add $n as your mobile vault: your new posts and media are sent to it."
            DeviceRole.BROWSER -> "Add $n as your browser vault: it gets your new notes while it's open."
            DeviceRole.PHONE -> "Add $n as another of your phones."
        }
    }

    const val UNREADABLE = "That code didn't read correctly. Try scanning again."
    const val OTHER_OWNER_TEXT = "That device belongs to another account. Only your own devices can be linked."
    const val ALREADY_LINKED_TEXT = "Already linked."
    const val EXPIRED_TEXT = "This code has expired. Show a new one."
    const val ABORT_TEXT = "Another device tried to use this code. Start again, and only show your code to your own device."

    fun text(refusal: Refusal): String = when (refusal) {
        Refusal.NotPairing -> "That isn't a Nostr Vault pairing code."
        Refusal.UnsupportedVersion -> "That code is from a newer Nostr Vault. Update this app and try again."
        Refusal.Malformed, Refusal.BadAddress, Refusal.MissingOwner, Refusal.BadCode, Refusal.NameTooLong -> UNREADABLE
        Refusal.UnknownRole -> "This version can't link that kind of device. Update this app and try again."
        Refusal.OwnAddress -> "That's this device's own code."
    }

    fun switchToText(accountName: String): String {
        val n = accountName.trim().ifEmpty { "that account" }
        return "This is $n's device. Switch to $n first."
    }

    fun otherRoleText(role: DeviceRole): String =
        "This device is already added as your ${roleWord(role)}. Remove it in Mesh settings first."

    fun roleWord(role: DeviceRole): String = when (role) {
        DeviceRole.PHONE -> "phone"
        DeviceRole.MAC -> "Mac"
        DeviceRole.HOME_VAULT -> "mobile vault"
        DeviceRole.BROWSER -> "browser vault"
    }

    /** "npub1abc…wxyz", as shortAccountNpub and iOS. */
    fun shortAddress(npub: String): String = if (npub.length <= 12) npub else npub.take(8) + "…" + npub.takeLast(4)

    fun displayName(name: String): String = name.trim().ifEmpty { "this device" }

    // ---- Hello and ack (the decrypted content of a kind-21195 event) ----

    /** [accounts]: `a`, the sender's signing accounts (npubs), optional. */
    data class Hello(val secret: String, val name: String, val role: DeviceRole, val owner: String, val time: Long, val accounts: List<String> = emptyList())

    /** [words]: A linked by Accept with the check words, so B needs its own tap. */
    data class Ack(val digest: String, val words: Boolean)

    fun helloJson(secret: String, name: String, role: DeviceRole, owner: String, time: Long, accounts: List<String> = emptyList()): String {
        val parts = mutableListOf("\"v\":1", "\"s\":${jsonString(secret)}")
        val n = cleanName(name)
        if (n.isNotEmpty()) parts += "\"n\":${jsonString(n)}"
        parts += listOf("\"r\":${jsonString(wire(role))}", "\"o\":${jsonString(owner)}", "\"t\":$time")
        val a = wireAccounts(accounts, owner)
        if (a.isNotEmpty()) parts += "\"a\":[" + a.joinToString(",", transform = ::jsonString) + "]"
        return "{" + parts.joinToString(",") + "}"
    }

    fun ackJson(digest: String, words: Boolean): String =
        "{\"v\":1,\"ack\":true,\"d\":${jsonString(digest)}" + (if (words) ",\"w\":true}" else "}")

    fun parseHello(text: String): Hello? {
        val d = jsonObject(text) ?: return null
        if (intOf(d["v"]) != 1L || d.containsKey("ack")) return null
        val s = stringOf(d["s"]) ?: return null
        if (secretBytes(s) == null) return null
        val role = roleFromWire(stringOf(d["r"])) ?: return null
        val ownerHex = npubHex(stringOf(d["o"])) ?: return null
        val t = intOf(d["t"]) ?: return null
        val n = if (d.containsKey("n")) stringOf(d["n"]) ?: return null else ""
        val name = n.trim()
        if (name.codePointCount(0, name.length) > NAME_MAX) return null
        return Hello(s, name, role, npub(ownerHex), t, readAccounts(d["a"]))
    }

    fun parseAck(text: String): Ack? {
        val d = jsonObject(text) ?: return null
        if (intOf(d["v"]) != 1L) return null
        val ack = d["ack"] as? JsonPrimitive ?: return null
        if (ack.isString || ack.booleanOrNull != true) return null
        val digest = stringOf(d["d"]) ?: return null
        if (digest.length != 64 || digest.any { it !in "0123456789abcdef" }) return null
        var words = false
        if (d.containsKey("w")) {
            val w = d["w"] as? JsonPrimitive ?: return null
            if (w.isString) return null
            words = w.booleanOrNull ?: return null
        }
        return Ack(digest, words)
    }

    // ---- Digests ----

    /**
     * The ack's proof. Scan path ([bSecret] given): hex SHA-256(s_A ‖ s_B ‖ m_A ‖ m_B), which only a device that read
     * B's code can make (Tron, PR 1700). Accept path (`w`): hex SHA-256(s_A ‖ m_A ‖ m_B), and B also needs its own
     * words tap (Tron 2).
     */
    fun ackDigest(secret: String, aHex: String, bHex: String, bSecret: String? = null): String? {
        val s = secretBytes(secret) ?: return null
        val a = hexBytes(aHex)?.takeIf { it.size == 32 } ?: return null
        val b = hexBytes(bHex)?.takeIf { it.size == 32 } ?: return null
        val sb = if (bSecret == null) ByteArray(0) else secretBytes(bSecret) ?: return null
        return sha256(s + sb + a + b).joinToString("") { "%02x".format(it) }
    }

    /** The 4 check words on the Accept path: the first 44 bits of SHA-256(m_A ‖ m_B ‖ s_A), 11 bits a word. */
    fun checkWords(aHex: String, bHex: String, secret: String): List<String>? {
        val s = secretBytes(secret) ?: return null
        val a = hexBytes(aHex)?.takeIf { it.size == 32 } ?: return null
        val b = hexBytes(bHex)?.takeIf { it.size == 32 } ?: return null
        val h = sha256(a + b + s)
        var n = 0L
        for (i in 0 until 6) n = (n shl 8) or (h[i].toLong() and 0xff)
        n = n ushr 4
        return (0 until 4).map { i -> MeshPairingWords.list[((n ushr (11 * (3 - i))) and 2047).toInt()] }
    }

    // ---- Helpers ----

    /** A fresh one-time secret: 16 random bytes, base64url. */
    fun newSecret(): String = base64url(ByteArray(16).also { SecureRandom().nextBytes(it) })

    /** The 32-byte key of an npub as hex, or null. Upper or lower case, never mixed. */
    fun npubHex(s: String?): String? {
        if (s == null || s.length != 63) return null
        if (s.lowercase() != s && s.uppercase() != s) return null
        val lower = s.lowercase()
        if (!lower.startsWith("npub1")) return null
        val data = IntArray(58)
        for (i in 0 until 58) data[i] = CHARSET.indexOf(lower[5 + i]).takeIf { it >= 0 } ?: return null
        if (polymod(hrpExpand("npub") + data) != 1) return null
        val bytes = fiveToEight(data.copyOfRange(0, 52)) ?: return null
        return if (bytes.size == 32) bytes.joinToString("") { "%02x".format(it) } else null
    }

    fun npub(hex: String): String {
        val bytes = hexBytes(hex)?.takeIf { it.size == 32 } ?: return hex
        val data5 = mutableListOf<Int>()
        var acc = 0
        var bits = 0
        for (b in bytes) {
            acc = (acc shl 8) or (b.toInt() and 0xff)
            bits += 8
            while (bits >= 5) { bits -= 5; data5 += (acc ushr bits) and 31 }
        }
        if (bits > 0) data5 += (acc shl (5 - bits)) and 31
        val values = hrpExpand("npub") + data5.toIntArray() + IntArray(6)
        val mod = polymod(values) xor 1
        val checksum = (0 until 6).map { (mod ushr (5 * (5 - it))) and 31 }
        return "npub1" + (data5 + checksum).joinToString("") { CHARSET[it].toString() }
    }

    fun secretBytes(s: String): ByteArray? {
        if (s.length != 22 || s.any { it !in B64 }) return null
        val d = try { Base64.getUrlDecoder().decode(s) } catch (_: IllegalArgumentException) { return null }
        return if (d.size == 16 && base64url(d) == s) d else null
    }

    fun base64url(d: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(d)

    fun cleanName(name: String): String {
        val t = name.trim()
        val count = t.codePointCount(0, t.length)
        return if (count <= NAME_MAX) t else t.substring(0, t.offsetByCodePoints(0, NAME_MAX))
    }

    fun percentEncode(s: String): String = buildString {
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = (b.toInt() and 0xff).toChar()
            if (c in UNRESERVED) append(c) else append("%%%02X".format(b.toInt() and 0xff))
        }
    }

    fun percentDecode(s: String): String? {
        val out = java.io.ByteArrayOutputStream()
        val bytes = s.toByteArray(Charsets.UTF_8)
        var i = 0
        while (i < bytes.size) {
            val c = bytes[i].toInt() and 0xff
            if (c == '%'.code) {
                if (i + 2 >= bytes.size) return null
                val hi = nibble(bytes[i + 1].toInt().toChar())
                val lo = nibble(bytes[i + 2].toInt().toChar())
                if (hi < 0 || lo < 0) return null
                out.write(hi * 16 + lo)
                i += 3
            } else {
                out.write(c)
                i += 1
            }
        }
        val decoder = Charsets.UTF_8.newDecoder()
        return try { decoder.decode(java.nio.ByteBuffer.wrap(out.toByteArray())).toString() } catch (_: java.nio.charset.CharacterCodingException) { null }
    }

    private const val CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    private const val B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

    private fun hrpExpand(hrp: String): IntArray =
        (hrp.map { it.code shr 5 } + 0 + hrp.map { it.code and 31 }).toIntArray()

    private fun polymod(values: IntArray): Int {
        val gen = intArrayOf(0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)
        var chk = 1
        for (v in values) {
            val top = chk ushr 25
            chk = ((chk and 0x1ffffff) shl 5) xor v
            for (i in 0 until 5) if ((top ushr i) and 1 == 1) chk = chk xor gen[i]
        }
        return chk
    }

    private fun fiveToEight(data: IntArray): ByteArray? {
        var acc = 0
        var bits = 0
        val out = mutableListOf<Byte>()
        for (v in data) {
            acc = (acc shl 5) or v
            bits += 5
            while (bits >= 8) { bits -= 8; out += ((acc ushr bits) and 0xff).toByte() }
        }
        if (bits >= 5 || ((acc shl (8 - bits)) and 0xff) != 0) return null
        return out.toByteArray()
    }

    private fun hexBytes(hex: String): ByteArray? {
        if (hex.length % 2 != 0) return null
        return ByteArray(hex.length / 2) { i ->
            val hi = nibble(hex[i * 2])
            val lo = nibble(hex[i * 2 + 1])
            if (hi < 0 || lo < 0) return null
            (hi * 16 + lo).toByte()
        }
    }

    /** An ASCII hex digit's value, or -1 (Character.digit also takes other scripts' digits). */
    private fun nibble(c: Char): Int = when (c) {
        in '0'..'9' -> c - '0'
        in 'a'..'f' -> c - 'a' + 10
        in 'A'..'F' -> c - 'A' + 10
        else -> -1
    }

    private fun sha256(b: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(b)

    private fun jsonString(s: String): String = JsonPrimitive(s).toString()

    private fun jsonObject(text: String): JsonObject? =
        try { Json.parseToJsonElement(text) as? JsonObject } catch (_: Exception) { null }

    private fun stringOf(e: Any?): String? = (e as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** A JSON integer (not a string, bool or fraction). */
    private fun intOf(e: Any?): Long? {
        val p = e as? JsonPrimitive ?: return null
        if (p.isString || p.booleanOrNull != null) return null
        return p.longOrNull
    }
}
