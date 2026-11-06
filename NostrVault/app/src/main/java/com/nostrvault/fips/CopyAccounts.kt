package com.nostrvault.fips

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull

/**
 * The vault's accounts in a copy (docs/MESH_COPY_V2_CONTRACT.md §3.4, `accounts-refuse-cases.json`,
 * `accounts-merge-cases.json`): npubs and names only, never a key. The app keeps [FILE] in the relay root current
 * with its own accounts and their names; after a copy or a catch-up the engine merges the other device's accounts
 * into it, and the app asks which of those to add here (look-only). Pure. Twin of iOS `CopyAccounts.swift`.
 */
object CopyAccounts {
    const val FILE = "copy-accounts.json"
    const val MAX_ACCOUNTS = 64
    /** A name, in Unicode code points. */
    const val NAME_MAX = 80
    const val MAX_SIZE = 64 shl 10

    data class Account(val npub: String, val name: String = "")

    /** The engine's refusal reasons (`copyAccountsRefusal`), as the fixtures name them. */
    enum class Refusal(val code: String) {
        BAD_VERSION("bad_version"), SECRET_VALUE("secret_value"), UNKNOWN_KEY("unknown_key"),
        BAD_NPUB("bad_npub"), BAD_NAME("bad_name"), TOO_MANY("too_many"),
    }

    sealed interface Checked {
        data class Ok(val accounts: List<Account>) : Checked
        data class Refused(val refusal: Refusal) : Checked
    }

    // ---- The refuse check (the engine's copyAccountsRefusal) ----

    /**
     * The file's accounts, or why it may not be written, read or handed to AddAccountsC. Same order as the engine:
     * size, JSON, secrets anywhere, fields and types, version, count, npubs, names.
     */
    fun check(raw: String): Checked {
        if (raw.toByteArray(Charsets.UTF_8).size > MAX_SIZE) return refused(Refusal.TOO_MANY)
        val whole = runCatching { Json.parseToJsonElement(raw) }.getOrNull() ?: return refused(Refusal.BAD_VERSION)
        if (secretAnywhere(whole)) return refused(Refusal.SECRET_VALUE)
        val o = whole as? JsonObject ?: return refused(Refusal.UNKNOWN_KEY)
        if (!FILE_KEYS.containsAll(o.keys)) return refused(Refusal.UNKNOWN_KEY)
        val v = intField(o["v"]) ?: return refused(Refusal.UNKNOWN_KEY)
        intField(o["updated_at"]) ?: return refused(Refusal.UNKNOWN_KEY)
        val accounts = mutableListOf<Account>()
        val list = o["accounts"]
        if (list != null && list != JsonNull) {
            if (list !is JsonArray) return refused(Refusal.UNKNOWN_KEY)
            for (item in list) {
                val a = item as? JsonObject ?: return refused(Refusal.UNKNOWN_KEY)
                if (!ACCOUNT_KEYS.containsAll(a.keys)) return refused(Refusal.UNKNOWN_KEY)
                val npub = stringField(a["npub"]) ?: return refused(Refusal.UNKNOWN_KEY)
                val name = stringField(a["name"]) ?: return refused(Refusal.UNKNOWN_KEY)
                accounts += Account(npub, name)
            }
        }
        if (v != 1L) return refused(Refusal.BAD_VERSION)
        if (accounts.size !in 1..MAX_ACCOUNTS) return refused(Refusal.TOO_MANY)
        for (a in accounts) {
            if (MeshPairing.npubHex(a.npub) == null) return refused(Refusal.BAD_NPUB)
            if (a.name.codePointCount(0, a.name.length) > NAME_MAX) return refused(Refusal.BAD_NAME)
        }
        return Checked.Ok(accounts)
    }

    /** The accounts in [raw], or empty when it is missing or refused. */
    fun accountsIn(raw: String?): List<Account> = (raw?.let(::check) as? Checked.Ok)?.accounts.orEmpty()

    /** `{"v":1,"updated_at":…,"accounts":[…]}`, only when it passes [check]. */
    fun fileJson(accounts: List<Account>, updatedAt: Long): String? {
        val list = JsonArray(accounts.map { a ->
            JsonObject(if (a.name.isEmpty()) mapOf("npub" to JsonPrimitive(a.npub)) else mapOf("npub" to JsonPrimitive(a.npub), "name" to JsonPrimitive(a.name)))
        })
        val out = JsonObject(linkedMapOf("v" to JsonPrimitive(1), "updated_at" to JsonPrimitive(updatedAt), "accounts" to list)).toString()
        return out.takeIf { check(it) is Checked.Ok }
    }

    // ---- Merging (the engine's mergeCopyAccounts) ----

    /** Mine, then theirs that are new, in order. A name I have stays; a missing one is filled. Nothing is removed. */
    fun merge(mine: List<Account>, theirs: List<Account>): List<Account> {
        val out = mine.toMutableList()
        val at = HashMap<String, Int>()
        out.forEachIndexed { i, a -> at[a.npub] = i }
        for (a in theirs) {
            val i = at[a.npub]
            if (i != null) {
                if (out[i].name.isEmpty()) out[i] = out[i].copy(name = a.name)
                continue
            }
            at[a.npub] = out.size
            out += a
        }
        return out
    }

    /** Whether [theirs] (npubs) holds one of [mine] (hex keys). */
    fun shares(mine: Set<String>, theirs: List<String>): Boolean = theirs.any { n -> MeshPairing.npubHex(n)?.let(mine::contains) == true }

    // ---- This app's side ----

    /**
     * The file this app writes: its own accounts (owner first) with the names it knows now, then every other account
     * already in the file (what a copy or catch-up brought). Own names win; nothing already in the file is dropped.
     */
    fun ownFile(own: List<Account>, existing: List<Account>): List<Account> {
        val mine = own.map { a -> if (a.name.isNotEmpty()) a else a.copy(name = existing.firstOrNull { it.npub == a.npub }?.name.orEmpty()) }
        return merge(mine, existing).take(MAX_ACCOUNTS)
    }

    /** The accounts to ask about: in the file, not this device's own, and not settled (asked already, or own once). */
    fun offered(file: List<Account>, ownHex: Set<String>, settledHex: Set<String>): List<Account> {
        val seen = HashSet<String>()
        return file.filter { a ->
            val hex = MeshPairing.npubHex(a.npub) ?: return@filter false
            hex !in ownHex && hex !in settledHex && seen.add(hex)
        }
    }

    /** What an answer does: every offered account is [settle]d (hex); only the ticked ones are [add]ed. */
    data class Answer(val settle: Set<String>, val add: List<Account>)

    /** [ticked] (npubs) out of [offered]: anything not offered is never added. */
    fun answer(offered: List<Account>, ticked: Collection<String>): Answer = Answer(
        settle = offered.mapNotNull { MeshPairing.npubHex(it.npub) }.toSet(),
        add = offered.filter { it.npub in ticked },
    )

    /** The JSON for AddAccountsC: the ticked accounts in the file's shape. */
    fun addJson(ticked: List<Account>, updatedAt: Long): String? = if (ticked.isEmpty()) null else fileJson(ticked, updatedAt)

    /** A name as written: trimmed, cut to [NAME_MAX], and left out when it reads as a key. */
    fun cleanName(raw: String?): String {
        val t = raw.orEmpty().trim()
        val cut = if (t.codePointCount(0, t.length) <= NAME_MAX) t else t.substring(0, t.offsetByCodePoints(0, NAME_MAX))
        return if (CopySettings.secretString(cut)) "" else cut
    }

    // ---- Helpers ----

    private val FILE_KEYS = setOf("v", "updated_at", "accounts")
    private val ACCOUNT_KEYS = setOf("npub", "name")

    private fun refused(r: Refusal) = Checked.Refused(r)

    private fun secretAnywhere(el: JsonElement): Boolean = when (el) {
        is JsonPrimitive -> el.isString && CopySettings.secretString(el.content)
        is JsonArray -> el.any(::secretAnywhere)
        is JsonObject -> el.any { (k, v) -> CopySettings.secretString(k) || secretAnywhere(v) }
    }

    /** An integer JSON number (not a string, bool or fraction) as Go's int64; absent or null is 0. */
    private fun intField(e: JsonElement?): Long? {
        if (e == null || e == JsonNull) return 0
        val p = e as? JsonPrimitive ?: return null
        if (p.isString || p.booleanOrNull != null) return null
        val d = p.doubleOrNull ?: return null
        if (d != Math.floor(d) || kotlin.math.abs(d) >= 9.2e18) return null
        return d.toLong()
    }

    /** A string, or absent / null (Go leaves the field empty). */
    private fun stringField(e: JsonElement?): String? {
        if (e == null || e == JsonNull) return ""
        return (e as? JsonPrimitive)?.takeIf { it.isString }?.content
    }
}
