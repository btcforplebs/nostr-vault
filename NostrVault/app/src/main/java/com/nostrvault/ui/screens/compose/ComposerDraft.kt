package com.nostrvault.ui.screens

import android.content.Context
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/**
 * An unsent article, recipe or poll, as its composer left it. Notes have
 * their own drafts (DraftService, synced to the private relay); these stay
 * on this device only. Twin of iOS `ComposerDraft`.
 */
@Serializable
data class ComposerDraft(
    val kind: Kind,
    val id: String = "",
    /** Epoch millis of the last save. */
    val updatedAt: Long = 0,

    // Article and recipe
    val title: String = "",
    val summary: String = "",
    /** The article body, or a recipe's chef's notes. */
    val body: String = "",
    /** True when a cover photo is saved beside the draft (see [ComposerDraftStore.coverFile]). */
    val hasCover: Boolean = false,
    /** The saved cover's type, since a file has none of its own to ask. */
    val coverMime: String? = null,

    // Recipe
    val prepTime: String = "",
    val cookTime: String = "",
    val servings: String = "",
    val ingredients: String = "",
    val directions: String = "",
    val categories: String = "",

    // Poll
    val question: String = "",
    val options: List<String> = if (kind == Kind.POLL) listOf("", "") else emptyList(),
    val multipleChoice: Boolean = false,
    /** [PollClosing] name; kept as text so an unknown one falls back instead of failing the file. */
    val closing: String? = null,
    /** Unix seconds, for a picked closing time. */
    val customEnd: Long? = null,
) {
    @Serializable
    enum class Kind(val listTitle: String) {
        ARTICLE("Article drafts"),
        RECIPE("Recipe drafts"),
        POLL("Poll drafts"),
    }

    /**
     * Whether there is anything worth keeping. A poll's closing choice alone,
     * or a form the user opened and left, is not a draft.
     */
    val hasContent: Boolean
        get() {
            val texts = when (kind) {
                Kind.ARTICLE -> listOf(title, summary, body)
                Kind.RECIPE -> listOf(title, summary, body, prepTime, cookTime, servings, ingredients, directions, categories)
                Kind.POLL -> listOf(question) + options
            }
            return hasCover || texts.any { it.isNotBlank() }
        }

    /** One line for the drafts list. */
    val previewTitle: String
        get() {
            val main = (if (kind == Kind.POLL) question else title).trim()
            if (main.isNotEmpty()) return main
            return if (kind == Kind.POLL) "Untitled poll" else "Untitled"
        }

    /** Second line for the drafts list: the start of the body, or the options. */
    val previewDetail: String
        get() {
            val text = when (kind) {
                Kind.ARTICLE -> body.ifEmpty { summary }
                Kind.RECIPE -> summary.ifEmpty { ingredients }
                Kind.POLL -> options.map { it.trim() }.filter { it.isNotEmpty() }.joinToString(" · ")
            }
            val flat = text.lines().joinToString(" ").trim()
            return if (flat.length <= 100) flat else flat.take(100) + "…"
        }

    /** Same content, ignoring the id and when it was saved; used to skip no-op saves. */
    fun sameContent(other: ComposerDraft): Boolean =
        copy(id = "", updatedAt = 0) == other.copy(id = "", updatedAt = 0)
}

/**
 * Composer drafts on disk: one JSON file per account, and each draft's cover
 * photo as its own file beside it so the list file stays small. Twin of iOS
 * `ComposerDraftStore`.
 */
@Singleton
class ComposerDraftStore(private val directory: File) {

    @Inject
    constructor(@ApplicationContext context: Context) : this(File(context.filesDir, DIRECTORY))

    private val json = Json { ignoreUnknownKeys = true }
    private val lock = Any()
    private val loaded = mutableMapOf<String, List<ComposerDraft>>()

    /** The account's drafts of [kind], newest first. */
    fun drafts(kind: ComposerDraft.Kind, account: String): List<ComposerDraft> = synchronized(lock) {
        draftsLocked(account).filter { it.kind == kind }.sortedByDescending { it.updatedAt }
    }

    fun draft(id: String, account: String): ComposerDraft? = synchronized(lock) {
        draftsLocked(account).firstOrNull { it.id == id }
    }

    /**
     * Adds or replaces the draft with `draft.id`. [cover] is the file to keep
     * as its cover (copied in unless it already is the saved one), or null to
     * remove it. A draft with no content is deleted instead, so clearing every
     * field of a saved draft does not leave an empty row in the list.
     */
    fun save(draft: ComposerDraft, cover: File?, account: String) {
        if (!draft.hasContent && cover == null) {
            delete(draft.id, account)
            return
        }
        synchronized(lock) {
            directory.mkdirs()
            val target = coverFile(draft.id, account)
            val hasCover = when {
                cover == null -> { target.delete(); false }
                cover.canonicalPath == target.canonicalPath -> target.exists()
                else -> runCatching { cover.copyTo(target, overwrite = true); true }
                    .onFailure { Log.w(TAG, "Couldn't keep the cover", it) }
                    .getOrDefault(false)
            }
            val stored = draft.copy(hasCover = hasCover, coverMime = draft.coverMime.takeIf { hasCover })
            val list = draftsLocked(account).toMutableList()
            val index = list.indexOfFirst { it.id == stored.id }
            if (index >= 0) list[index] = stored else list.add(stored)
            writeLocked(list, account)
        }
    }

    fun delete(id: String, account: String) = synchronized(lock) {
        coverFile(id, account).delete()
        val list = draftsLocked(account)
        val kept = list.filter { it.id != id }
        if (kept.size != list.size) writeLocked(kept, account)
    }

    /** The draft's saved cover, or null when it has none. */
    fun cover(draft: ComposerDraft, account: String): File? =
        coverFile(draft.id, account).takeIf { draft.hasCover && it.exists() }

    fun coverFile(id: String, account: String): File =
        File(directory, "cover_${safeKey(account)}_${id.replace('/', '_')}")

    fun listFile(account: String): File = File(directory, "composer_drafts_${safeKey(account)}.json")

    private fun draftsLocked(account: String): List<ComposerDraft> = loaded.getOrPut(account) {
        val file = listFile(account)
        if (!file.exists()) return@getOrPut emptyList()
        runCatching { json.decodeFromString<List<ComposerDraft>>(file.readText()) }
            .onFailure { Log.w(TAG, "Couldn't read composer drafts", it) }
            .getOrDefault(emptyList())
    }

    private fun writeLocked(list: List<ComposerDraft>, account: String) {
        loaded[account] = list
        runCatching {
            directory.mkdirs()
            // Written beside and renamed, so a crash mid-write leaves the old list.
            val tmp = File(directory, listFile(account).name + ".tmp")
            tmp.writeText(json.encodeToString(list))
            if (!tmp.renameTo(listFile(account))) error("rename failed")
        }.onFailure { Log.w(TAG, "Couldn't save composer drafts", it) }
    }

    companion object {
        private const val TAG = "ComposerDraftStore"
        const val DIRECTORY = "ComposerDrafts"

        fun safeKey(account: String): String = if (account.isEmpty()) "owner" else account.replace('/', '_')

        fun newId(): String = UUID.randomUUID().toString()
    }
}
