package com.nostrvault.shareportal

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * What the share sheet hands the app: one queued "do this with what I shared".
 *
 * Mirrors HavenApp/HavenApp/SharePortalKit/NVShareIntent.swift. The schema and
 * every rule below are docs/SHARE_PORTAL_CONTRACT.md §1; the shared fixtures
 * (Fixtures/SharePortal/envelope-cases.json) are the tests for both sides.
 *
 * Holds no secrets: no key, no NWC string. Everything in it came from another
 * app or from what the person typed, so [decode] trusts nothing and rejects
 * the whole intent when any part is out of shape.
 */
enum class ShareAction(val raw: String) {
    HIGHLIGHT("highlight"),
    BOOKMARK("bookmark"),
    PRIVATE_COPY("private_copy"),
    ARTICLE_CLIP("article_clip"),
    MEDIA_POST("media_post"),
    UPLOAD("upload"),
    RECIPE("recipe"),
    PROFILE("profile"),
    PAY("pay"),
    DM("dm"),
    STATUS("status"),
    CALENDAR("calendar"),
    LABEL("label");

    companion object {
        fun from(raw: String): ShareAction? = entries.firstOrNull { it.raw == raw }
    }
}

data class ShareSource(
    val url: String? = null,
    val title: String? = null,
    val text: String? = null,
    val selection: String? = null,
    val app: String? = null,
    val ldTypes: List<String> = emptyList(),
)

data class ShareFile(
    val name: String,
    val mime: String,
    val path: String,
    val bytes: Long,
)

data class ShareIntent(
    val id: String,
    val createdAt: Long,
    val action: ShareAction,
    val account: String? = null,
    val source: ShareSource = ShareSource(),
    val files: List<ShareFile> = emptyList(),
    val form: Map<String, String> = emptyMap(),
) {
    val v: Int get() = VERSION

    /** The review card flags an intent this old instead of acting as if it were fresh. */
    fun isStale(nowSeconds: Long): Boolean = nowSeconds - createdAt > STALE_AFTER_SECONDS

    fun encode(): String = Json.encodeToString(JsonObject.serializer(), toJson())

    fun toJson(): JsonObject = buildJsonObject {
        put("v", VERSION)
        put("id", id)
        put("created_at", createdAt)
        account?.let { put("account", it) }
        put("action", action.raw)
        put("source", buildJsonObject {
            source.url?.let { put("url", it) }
            source.title?.let { put("title", it) }
            source.text?.let { put("text", it) }
            source.selection?.let { put("selection", it) }
            source.app?.let { put("app", it) }
            if (source.ldTypes.isNotEmpty()) put("ld_types", buildJsonArray { source.ldTypes.forEach { add(JsonPrimitive(it)) } })
        })
        if (files.isNotEmpty()) put("files", buildJsonArray {
            files.forEach { f ->
                add(buildJsonObject {
                    put("name", f.name); put("mime", f.mime); put("path", f.path); put("bytes", f.bytes)
                })
            }
        })
        if (form.isNotEmpty()) put("form", buildJsonObject { form.forEach { (k, v) -> put(k, v) } })
    }

    companion object {
        const val VERSION = 1
        const val STALE_AFTER_SECONDS = 7L * 24 * 3600

        // Limits, in String.length (UTF-16) units, as in the contract.
        const val MAX_URL = 4_096
        const val MAX_TITLE = 1_000
        const val MAX_TEXT = 100_000
        const val MAX_SELECTION = 10_000
        const val MAX_APP = 200
        const val MAX_LD_TYPES = 20
        const val MAX_LD_TYPE = 100
        const val MAX_FILES = 20
        const val MAX_FORM_KEYS = 32
        const val MAX_FORM_KEY = 64
        const val MAX_FORM_VALUE = 20_000

        private val ID = Regex("^[A-Za-z0-9-]{1,64}$")
        private val NPUB = Regex("^npub1[02-9ac-hj-np-z]+$")

        fun isValidId(id: String): Boolean = ID.matches(id)

        /** A file name that is safe to join onto `files/<id>/`. */
        fun isValidFileName(name: String): Boolean =
            name.isNotEmpty() && name.length <= 255 && !name.startsWith(".") &&
                '/' !in name && '\\' !in name && '\u0000' !in name

        fun filePath(id: String, name: String): String = "files/$id/$name"

        /** Cut to [max] UTF-16 units without splitting a surrogate pair. */
        fun cap(value: String, max: Int): String {
            if (value.length <= max) return value
            var end = max
            if (end > 0 && Character.isHighSurrogate(value[end - 1])) end--
            return value.substring(0, end)
        }

        fun decode(raw: String): ShareIntent? {
            val root = runCatching { Json.parseToJsonElement(raw) }.getOrNull() ?: return null
            return decode(root)
        }

        fun decode(root: JsonElement): ShareIntent? {
            val o = root as? JsonObject ?: return null
            val v = (o["v"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull ?: return null
            if (v != VERSION.toLong()) return null
            val id = o.string("id") ?: return null
            if (!isValidId(id)) return null
            val createdAt = (o["created_at"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull ?: return null
            val action = o.string("action")?.let(ShareAction::from) ?: return null

            val account = when (val a = o["account"]) {
                null, JsonNull -> null
                is JsonPrimitive -> if (!a.isString) return null else a.content.trim()
                else -> return null
            }?.takeIf { it.isNotEmpty() }
            if (account != null && !NPUB.matches(account.lowercase())) return null

            val source = when (val s = o["source"]) {
                null, JsonNull -> ShareSource()
                is JsonObject -> decodeSource(s) ?: return null
                else -> return null
            }
            val files = when (val f = o["files"]) {
                null, JsonNull -> emptyList()
                is JsonArray -> decodeFiles(f, id) ?: return null
                else -> return null
            }
            val form = when (val f = o["form"]) {
                null, JsonNull -> emptyMap()
                is JsonObject -> decodeForm(f) ?: return null
                else -> return null
            }
            return ShareIntent(id, createdAt, action, account, source, files, form)
        }

        private fun decodeSource(s: JsonObject): ShareSource? {
            fun field(key: String, max: Int): Result<String?> = when (val e = s[key]) {
                null, JsonNull -> Result.success(null)
                is JsonPrimitive -> if (e.isString) Result.success(cap(e.content, max)) else Result.failure(IllegalArgumentException(key))
                else -> Result.failure(IllegalArgumentException(key))
            }
            val ld = when (val e = s["ld_types"]) {
                null, JsonNull -> emptyList()
                is JsonArray -> e.map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content ?: return null }
                    .take(MAX_LD_TYPES).map { cap(it, MAX_LD_TYPE) }
                else -> return null
            }
            return ShareSource(
                url = field("url", MAX_URL).getOrElse { return null },
                title = field("title", MAX_TITLE).getOrElse { return null },
                text = field("text", MAX_TEXT).getOrElse { return null },
                selection = field("selection", MAX_SELECTION).getOrElse { return null },
                app = field("app", MAX_APP).getOrElse { return null },
                ldTypes = ld,
            )
        }

        private fun decodeFiles(a: JsonArray, id: String): List<ShareFile>? {
            if (a.size > MAX_FILES) return null
            return a.map { e ->
                val f = e as? JsonObject ?: return null
                val name = f.string("name") ?: return null
                if (!isValidFileName(name) || name == "..") return null
                val path = f.string("path") ?: return null
                if (path != filePath(id, name)) return null
                val mime = f.string("mime")?.let { cap(it, 255) } ?: return null
                val bytes = (f["bytes"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull ?: return null
                if (bytes < 0) return null
                ShareFile(name, mime, path, bytes)
            }
        }

        private fun decodeForm(f: JsonObject): Map<String, String>? {
            if (f.size > MAX_FORM_KEYS) return null
            val out = LinkedHashMap<String, String>()
            for ((k, v) in f) {
                if (k.isEmpty() || k.length > MAX_FORM_KEY) return null
                val p = v as? JsonPrimitive ?: return null
                if (!p.isString) return null
                out[k] = cap(p.content, MAX_FORM_VALUE)
            }
            return out
        }

        private fun JsonObject.string(key: String): String? =
            (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
    }
}
