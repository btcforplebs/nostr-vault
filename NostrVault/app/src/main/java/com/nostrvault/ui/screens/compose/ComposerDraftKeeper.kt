package com.nostrvault.ui.screens

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Keeps one article, recipe or poll composer's draft on disk while it is
 * edited: a short pause after each change saves it, leaving the screen saves
 * it, publishing or discarding removes it. The draft belongs to the account
 * that opened the composer, even if another one becomes active meanwhile.
 * Twin of iOS `ComposerDraftKeeper`. Call it on the main thread.
 */
class ComposerDraftKeeper(
    val kind: ComposerDraft.Kind,
    val account: String,
    private val store: ComposerDraftStore,
    private val scope: CoroutineScope,
    private val now: () -> Long = System::currentTimeMillis,
) {
    /** The draft being edited, once it has been saved or picked from the list. */
    var draftId: String? = null
        private set
    private var lastSaved: ComposerDraft? = null
    private var lastCover: String? = null
    private var pending: Job? = null

    /**
     * The draft as it was when picked from the list, so Discard can put it
     * back instead of deleting work saved in an earlier session. Its cover is
     * copied aside, since editing overwrites the saved one.
     */
    private var opened: Pair<ComposerDraft, java.io.File?>? = null

    /**
     * Set after publish or discard, so a late autosave or leaving the screen
     * cannot bring the draft back.
     */
    private var finished = false

    private val _others = MutableStateFlow<List<ComposerDraft>>(emptyList())
    /** The other saved drafts of this kind, for the "saved drafts" row. */
    val others: StateFlow<List<ComposerDraft>> = _others.asStateFlow()

    init {
        refreshOthers()
    }

    /** Saves after a short pause, so typing writes once per pause, not per key. */
    fun changed(draft: ComposerDraft, cover: java.io.File?) {
        pending?.cancel()
        if (finished) return
        pending = scope.launch {
            delay(AUTOSAVE_DELAY_MS)
            saveNow(draft, cover)
        }
    }

    /** Writes the draft now if it differs from what is on disk. */
    fun saveNow(draft: ComposerDraft, cover: java.io.File?) {
        pending?.cancel()
        if (finished) return
        if (!draft.hasContent && cover == null && draftId == null) return
        val id = draftId ?: ComposerDraftStore.newId()
        val stamped = draft.copy(id = id, hasCover = cover != null)
        val coverKey = cover?.let { "${it.path}:${it.lastModified()}:${it.length()}" }
        lastSaved?.let { if (it.sameContent(stamped) && lastCover == coverKey) return }
        val saved = stamped.copy(updatedAt = now())
        store.save(saved, cover, account)
        draftId = id
        lastSaved = saved
        lastCover = coverKey
    }

    /** Switches the composer to a saved draft. Returns its cover file. */
    fun open(draft: ComposerDraft): java.io.File? {
        pending?.cancel()
        val cover = store.cover(draft, account)
        val coverCopy = cover?.let { src ->
            runCatching {
                java.io.File(src.parentFile, src.name + ".opened").also { src.copyTo(it, overwrite = true) }
            }.getOrNull()
        }
        opened?.second?.delete()
        draftId = draft.id
        lastSaved = draft
        lastCover = cover?.let { "${it.path}:${it.lastModified()}:${it.length()}" }
        opened = draft to coverCopy
        refreshOthers()
        return cover
    }

    /** True when the composer is editing a draft that was saved before. */
    val editsSavedDraft: Boolean get() = opened != null

    fun delete(draft: ComposerDraft) {
        store.delete(draft.id, account)
        refreshOthers()
    }

    /** The post went out: drop the draft. */
    fun finish() {
        pending?.cancel()
        finished = true
        draftId?.let { store.delete(it, account) }
        opened?.second?.delete()
    }

    /**
     * The user chose Discard: a new draft goes away, and one picked from the
     * list goes back to how it was when it was opened.
     */
    fun discard() {
        val (draft, cover) = opened ?: return finish()
        pending?.cancel()
        finished = true
        store.save(draft, cover, account)
        cover?.delete()
    }

    fun refreshOthers() {
        _others.value = store.drafts(kind, account).filter { it.id != draftId }
    }

    companion object {
        const val AUTOSAVE_DELAY_MS = 800L
    }
}
