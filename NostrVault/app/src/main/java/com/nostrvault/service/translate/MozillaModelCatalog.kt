package com.nostrvault.service.translate

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * Mozilla's list of translation models, the one Firefox reads: a Remote
 * Settings collection whose records each point at one file (model, shortlist
 * or vocabulary) for one direction and version. Pure parsing and choosing,
 * so it runs in a JVM test; [TranslationModelStore] does the downloads.
 */
object MozillaModelCatalog {

    /** The records list (public, no key). */
    const val RECORDS_URL =
        "https://firefox.settings.services.mozilla.com/v1/buckets/main/collections/translations-models/records"

    /** Where a record's `attachment.location` is served from. */
    const val ATTACHMENTS_BASE = "https://firefox-settings-attachments.cdn.mozilla.net/"

    data class ModelFile(
        val fileType: String,
        val fileName: String,
        val location: String,
        val sha256: String,
        val size: Long,
    ) {
        val url: String get() = ATTACHMENTS_BASE + location
    }

    /** The files one direction needs, all from the same version. */
    data class ModelSet(val from: String, val to: String, val version: String, val files: List<ModelFile>) {
        fun file(type: String): ModelFile? = files.firstOrNull { it.fileType == type }
        val model: ModelFile get() = requireNotNull(file("model"))
        val shortlist: ModelFile get() = requireNotNull(file("lex"))
        /** Source then target vocabulary; most models share one file for both. */
        val vocabs: List<ModelFile>
            get() = file("vocab")?.let { listOf(it, it) }
                ?: listOf(requireNotNull(file("srcvocab")), requireNotNull(file("trgvocab")))
    }

    private val json = Json { ignoreUnknownKeys = true }

    private data class Record(val from: String, val to: String, val version: String, val file: ModelFile, val filter: String)

    /**
     * Whether Firefox for Android on the release channel would use a record:
     * Remote Settings filter expressions decide that, and Mozilla uses them
     * for Nightly/Beta-only models and for Android-only (or not-Android) ones.
     * Anything this doesn't recognise is skipped.
     */
    internal fun appliesToAndroidRelease(filter: String): Boolean {
        val f = filter.trim()
        return f.isEmpty() || f == "env.appinfo.OS == 'Android'"
    }

    /**
     * The newest complete release (no "a" pre-release versions) Firefox for
     * Android would use for [from] -> [to] in Mozilla's codes, or null when
     * Mozilla has none.
     */
    fun pick(recordsJson: String, from: String, to: String): ModelSet? {
        val records = parse(recordsJson).filter { it.from == from && it.to == to && appliesToAndroidRelease(it.filter) }
        return records
            .groupBy { it.version }
            .filterKeys { releaseVersion(it) != null }
            .entries
            .sortedWith(compareByDescending<Map.Entry<String, List<Record>>> { releaseVersion(it.key)!!.first }
                .thenByDescending { releaseVersion(it.key)!!.second })
            .firstNotNullOfOrNull { (version, recs) ->
                val set = ModelSet(from, to, version, recs.map { it.file }.distinctBy { it.fileType })
                set.takeIf { isComplete(it) }
            }
    }

    private fun isComplete(set: ModelSet): Boolean =
        set.file("model") != null && set.file("lex") != null &&
            (set.file("vocab") != null || (set.file("srcvocab") != null && set.file("trgvocab") != null))

    /** "2.1" -> (2, 1); pre-releases ("2.0a1") and anything odd -> null. */
    internal fun releaseVersion(version: String): Pair<Int, Int>? {
        val match = Regex("""^(\d+)\.(\d+)$""").matchEntire(version) ?: return null
        return match.groupValues[1].toInt() to match.groupValues[2].toInt()
    }

    private fun parse(recordsJson: String): List<Record> {
        val root = json.parseToJsonElement(recordsJson).jsonObject
        val data = root["data"]?.jsonArray ?: return emptyList()
        return data.mapNotNull { element ->
            val r = element as? JsonObject ?: return@mapNotNull null
            val attachment = r["attachment"] as? JsonObject ?: return@mapNotNull null
            fun JsonObject.str(key: String) = this[key]?.jsonPrimitive?.contentOrNull
            val from = r.str("fromLang") ?: return@mapNotNull null
            val to = r.str("toLang") ?: return@mapNotNull null
            val version = r.str("version") ?: return@mapNotNull null
            val type = r.str("fileType") ?: return@mapNotNull null
            val location = attachment.str("location") ?: return@mapNotNull null
            val hash = attachment.str("hash") ?: return@mapNotNull null
            val name = attachment.str("filename") ?: r.str("name") ?: return@mapNotNull null
            // Only plain file names go to disk.
            if (name.contains('/') || name.contains('\\') || name.startsWith(".")) return@mapNotNull null
            val size = attachment["size"]?.jsonPrimitive?.longOrNull ?: 0L
            Record(
                from = from,
                to = to,
                version = version,
                file = ModelFile(type, name, location, hash.lowercase(), size),
                filter = r.str("filter_expression").orEmpty(),
            )
        }
    }

    /**
     * Bergamot's settings for one direction, as Firefox Translations runs it:
     * greedy search, the shortlist, int8 matrix maths, one thread (the caller's).
     * Paths are absolute files on the phone.
     */
    fun bergamotConfig(model: String, srcVocab: String, trgVocab: String, shortlist: String): String {
        fun q(path: String) = "\"" + path.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
        val precision = if (model.contains("alphas")) "int8shiftAlphaAll" else "int8shiftAll"
        return """
            models:
              - ${q(model)}
            vocabs:
              - ${q(srcVocab)}
              - ${q(trgVocab)}
            shortlist:
              - ${q(shortlist)}
              - false
            beam-size: 1
            normalize: 1.0
            word-penalty: 0
            max-length-break: 128
            mini-batch-words: 1024
            workspace: 128
            max-length-factor: 2.0
            skip-cost: true
            cpu-threads: 0
            quiet: true
            quiet-translation: true
            gemm-precision: $precision
        """.trimIndent() + "\n"
    }
}
