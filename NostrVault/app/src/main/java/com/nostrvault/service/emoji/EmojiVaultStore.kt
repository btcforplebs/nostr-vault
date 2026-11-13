package com.nostrvault.service.emoji

import android.content.Context
import android.net.Uri
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.fips.EmojiNote
import com.nostrvault.fips.EmojiNoteIndex
import com.nostrvault.fips.HomeVaultSender
import com.nostrvault.service.BlobStream
import com.nostrvault.service.BlossomService
import com.nostrvault.service.EmojiListRepository
import com.nostrvault.service.NostrEvent
import com.nostrvault.service.NostrService
import com.nostrvault.service.OwnVaultAuth
import com.nostrvault.service.StreamedBlob
import com.nostrvault.service.VaultSocket
import com.nostrvault.service.localBlobFile
import com.nostrvault.relay.vaultAuthRelayTag
import com.nostrvault.service.ownVaultAuth
import com.nostrvault.service.sniffContentType
import com.nostrvault.service.storeStreamed
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import okhttp3.Request
import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import java.util.zip.ZipInputStream
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The vault's custom emoji copies (RESEARCH/NV_CUSTOM_EMOJI_PLAN.md §4.1, Logen's picks 1-3): images saved into this
 * device's vault only on a Save copies tap (or a zip import), each with an emoji note on the home vault's `/files`,
 * signed with this device's mesh key, so every paired device knows it is an emoji and Media leaves it out. Publishes
 * nothing public: the set events it resends are other people's signed 30030s, as they are. Apple twin:
 * `EmojiVaultStore.swift`.
 */
@Singleton
class EmojiVaultStore @Inject constructor(
    @ApplicationContext private val context: Context,
    private val blossomService: BlossomService,
    private val homeVault: HomeVaultSender,
    private val nostrService: NostrService,
    private val configStore: ConfigStore,
    private val emojiList: EmojiListRepository,
) {
    /** One saved image, as this device saved it. */
    @Serializable
    data class Saved(
        val sha256: String,
        val mime: String,
        val size: Long,
        val codes: List<List<String>>,
        val sets: List<String>,
        /** The blob was in the vault before (a photo too): Media keeps it. */
        val alsoMedia: Boolean = false,
    )

    /** An emoji whose image could not be found anywhere. */
    @Serializable
    data class Dead(val url: String, val codes: List<String>, val sets: List<String>)

    @Serializable
    private data class Disk(val owner: String = "", val saved: List<Saved> = emptyList(), val dead: List<Dead> = emptyList())

    /** A run on screen: [done] of [total], then the tally line. */
    data class Progress(val running: Boolean = false, val done: Int = 0, val total: Int = 0, val tally: EmojiCopyRules.Tally? = null, val error: String? = null)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val file get() = File(context.filesDir, "emoji_copies.json")
    private val lock = Any()

    private val index = EmojiNoteIndex()
    private var disk = Disk()

    private val _saved = MutableStateFlow<Map<String, Saved>>(emptyMap())
    val saved: StateFlow<Map<String, Saved>> = _saved.asStateFlow()

    private val _dead = MutableStateFlow<List<Dead>>(emptyList())
    val dead: StateFlow<List<Dead>> = _dead.asStateFlow()

    /** Every emoji note heard on `/files` (this device's and the owner's other devices'). */
    private val _notes = MutableStateFlow<List<EmojiNote>>(emptyList())
    val notes: StateFlow<List<EmojiNote>> = _notes.asStateFlow()

    /** Hashes Media leaves out: emoji copies with no plain note and not a photo here too. */
    private val _hiddenFromMedia = MutableStateFlow<Set<String>>(emptySet())
    val hiddenFromMedia: StateFlow<Set<String>> = _hiddenFromMedia.asStateFlow()

    private val _progress = MutableStateFlow(Progress())
    val progress: StateFlow<Progress> = _progress.asStateFlow()

    private var run: Job? = null

    @Volatile
    private var loaded = false

    init {
        scope.launch { ensureLoaded() }
    }

    /** Reads the file once, before anything changes or is shown. */
    private fun ensureLoaded() {
        val read = synchronized(lock) {
            if (loaded) return
            loaded = true
            runCatching { json.decodeFromString(Disk.serializer(), file.readText()) }.getOrNull()?.also { disk = it }
        }
        if (read != null) publishState()
    }

    /** One `/files` event from a live subscription (Media tab, Emoji page). */
    fun onFileNote(event: JsonObject) {
        scope.launch {
            ensureLoaded()
            val changed = synchronized(lock) {
                index.owner = nostrService.ownerHexPubkey.takeIf { it.isNotEmpty() }
                index.apply(event)
            }
            if (changed) publishState()
        }
    }

    /** Save copies for [sets] (the 10030's sets on the page). One run at a time. */
    fun saveCopies(sets: List<EmojiListRepository.EmojiSet>) = start { runSave(sets) }

    /** Zip import: images matching an emoji in the saved sets become copies; the rest are listed and skipped. */
    fun importZip(uri: Uri, sets: List<EmojiListRepository.EmojiSet>) = start { runZip(uri, sets) }

    private fun start(body: suspend () -> Unit) {
        if (run?.isActive == true) return
        val owner = nostrService.ownerHexPubkey
        if (owner.isEmpty() || nostrService.activeHexPubkey != owner) {
            _progress.value = Progress(error = "Switch to your vault's account to save emoji copies.")
            return
        }
        run = scope.launch {
            try {
                ensureLoaded()
                ownerScoped(owner)
                body()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "emoji copies run failed: ${e.message}")
                _progress.value = _progress.value.copy(running = false, error = "Stopped: ${e.message}")
            }
        }
    }

    private suspend fun runSave(sets: List<EmojiListRepository.EmojiSet>) {
        val wanted = EmojiCopyRules.wanted(sets)
        _progress.value = Progress(running = true, total = wanted.size)
        keepSetEvents(sets.map { it.address })
        val auth = blossomService.ownVaultAuth(listOf("upload"))
            ?: return run { _progress.value = Progress(error = "Could not sign the save into your vault. Nothing was saved.") }
        var tally = EmojiCopyRules.Tally()
        val dead = mutableListOf<Dead>()
        val savedByUrl = savedByUrl()
        for ((i, w) in wanted.withIndex()) {
            val known = savedByUrl[w.url]
            tally = if (known != null && blossomService.localBlobFile(known) != null) {
                record(known, null, w)
                tally.copy(already = tally.already + 1)
            } else {
                when (val got = fetch(w.url)) {
                    is Fetch.Ok -> store(got, w, auth, tally)
                    is Fetch.Skipped -> {
                        if (got.why == EmojiCopyRules.Skip.DEAD) dead += Dead(w.url, w.codes.map { it[0] }, w.sets)
                        tally.skip(got.why)
                    }
                }
            }
            _progress.value = Progress(running = true, done = i + 1, total = wanted.size, tally = tally)
        }
        // This run's answer replaces what an earlier run said about the same links.
        val tried = wanted.map { it.url }.toSet()
        synchronized(lock) { disk = disk.copy(dead = disk.dead.filter { it.url !in tried } + dead) }
        persist()
        homeVault.drainSoon()
        _progress.value = Progress(done = wanted.size, total = wanted.size, tally = tally)
    }

    private suspend fun runZip(uri: Uri, sets: List<EmojiListRepository.EmojiSet>) {
        _progress.value = Progress(running = true)
        val auth = blossomService.ownVaultAuth(listOf("upload"))
            ?: return run { _progress.value = Progress(error = "Could not sign the save into your vault. Nothing was saved.") }
        var tally = EmojiCopyRules.Tally()
        var seen = 0
        val matchedUrls = mutableSetOf<String>()
        withContext(Dispatchers.IO) {
            val input = context.contentResolver.openInputStream(uri) ?: error("the zip could not be opened")
            ZipInputStream(input.buffered()).use { zip ->
                while (true) {
                    val entry = zip.nextEntry ?: break
                    if (entry.isDirectory || !EmojiCopyRules.zipEntryLooksLikeImage(entry.name)) continue
                    seen++
                    val bytes = readCapped(zip)
                    tally = when {
                        bytes == null -> tally.skip(EmojiCopyRules.Skip.TOO_BIG)
                        tally.capReached(bytes.size.toLong()) -> tally.skip(EmojiCopyRules.Skip.OVER_CAP)
                        else -> {
                            val sha = sha256(bytes)
                            val match = EmojiCopyRules.zipMatch(entry.name, sha, sets)
                            if (match == null) tally.skip(EmojiCopyRules.Skip.NO_MATCH) else {
                                matchedUrls += match.url
                                store(Fetch.Ok(bytes, sha, sniffContentType(bytes.copyOf(minOf(bytes.size, 64)))), match, auth, tally)
                            }
                        }
                    }
                    _progress.value = Progress(running = true, done = seen, total = seen, tally = tally)
                }
            }
        }
        // A dead link the zip filled is no longer dead.
        synchronized(lock) { disk = disk.copy(dead = disk.dead.filter { it.url !in matchedUrls }) }
        persist()
        homeVault.drainSoon()
        _progress.value = Progress(done = seen, total = seen, tally = tally)
    }

    private suspend fun store(got: Fetch.Ok, w: EmojiCopyRules.Wanted, auth: OwnVaultAuth, tally: EmojiCopyRules.Tally): EmojiCopyRules.Tally {
        EmojiCopyRules.refusal(got.mime, got.bytes.size.toLong())?.let { return tally.skip(it) }
        if (tally.capReached(got.bytes.size.toLong())) return tally.skip(EmojiCopyRules.Skip.OVER_CAP)
        val wasThere = blossomService.localBlobFile(got.sha256) != null
        if (!wasThere) {
            val temp = File.createTempFile("emoji-${got.sha256.take(12)}-", ".blob", BlobStream.tempDir())
            temp.writeBytes(got.bytes)
            val ok = blossomService.storeStreamed(StreamedBlob(temp, got.sha256, got.bytes.size.toLong()), got.mime, auth)
            if (!ok) return tally.skip(EmojiCopyRules.Skip.NOT_STORED)
        }
        record(got.sha256, Saved(got.sha256, got.mime, got.bytes.size.toLong(), w.codes, w.sets, alsoMedia = wasThere && !isOurs(got.sha256)), w)
        return tally.copy(saved = tally.saved + 1, bytes = tally.bytes + got.bytes.size)
    }

    /** Records a copy (new, or more codes/sets for one already saved) and queues its emoji note. */
    private fun record(sha256: String, fresh: Saved?, w: EmojiCopyRules.Wanted) {
        val merged = synchronized(lock) {
            val old = disk.saved.firstOrNull { it.sha256 == sha256 }
            val base = old ?: fresh ?: return
            val next = base.copy(codes = (base.codes + w.codes).distinct(), sets = (base.sets + w.sets).distinct())
            disk = disk.copy(saved = disk.saved.filterNot { it.sha256 == sha256 } + next)
            next
        }
        homeVault.offerEmojiNote(merged.sha256, merged.mime, merged.size, merged.codes, merged.sets)
        publishState()
    }

    private fun isOurs(sha256: String): Boolean = synchronized(lock) { disk.saved.any { it.sha256 == sha256 } }

    private fun savedByUrl(): Map<String, String> = synchronized(lock) {
        buildMap {
            for (s in disk.saved) for (c in s.codes) if (c.size >= 2) putIfAbsent(c[1], s.sha256)
            putAll(index.hashByUrl().filterKeys { it !in this })
        }
    }

    private sealed interface Fetch {
        class Ok(val bytes: ByteArray, val sha256: String, val mime: String) : Fetch
        data class Skipped(val why: EmojiCopyRules.Skip) : Fetch
    }

    /** The link, then (dead) the same hash on the person's servers and public ones; a copy counts only if it hashes right. */
    private suspend fun fetch(url: String): Fetch = withContext(Dispatchers.IO) {
        when (val first = download(url, expect = null)) {
            is Fetch.Ok -> return@withContext first
            is Fetch.Skipped -> if (first.why != EmojiCopyRules.Skip.DEAD) return@withContext first
        }
        val sha = EmojiCopyRules.hashInUrl(url)
        for (alt in EmojiCopyRules.searchUrls(url, configStore.config.value.activeBlossomMirrors)) {
            val got = download(alt, expect = sha)
            if (got is Fetch.Ok) return@withContext got
        }
        Fetch.Skipped(EmojiCopyRules.Skip.DEAD)
    }

    private fun download(url: String, expect: String?): Fetch = try {
        val request = Request.Builder().url(url).get().build()
        blossomService.publicOnlyClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) return Fetch.Skipped(EmojiCopyRules.Skip.DEAD)
            val body = response.body ?: return Fetch.Skipped(EmojiCopyRules.Skip.DEAD)
            if (body.contentLength() > EmojiCopyRules.MAX_IMAGE_BYTES) return Fetch.Skipped(EmojiCopyRules.Skip.TOO_BIG)
            val bytes = body.byteStream().use(::readCapped) ?: return Fetch.Skipped(EmojiCopyRules.Skip.TOO_BIG)
            val sha = sha256(bytes)
            if (expect != null && sha != expect) return Fetch.Skipped(EmojiCopyRules.Skip.DEAD)
            val header = response.header("Content-Type")?.substringBefore(';')?.trim()?.lowercase()
            val mime = header?.takeIf { it in EmojiCopyRules.IMAGE_TYPES } ?: sniffContentType(bytes.copyOf(minOf(bytes.size, 64)))
            Fetch.Ok(bytes, sha, mime)
        }
    } catch (e: Exception) {
        Fetch.Skipped(EmojiCopyRules.Skip.DEAD)
    }

    /** At most [EmojiCopyRules.MAX_IMAGE_BYTES]; null when there is more. */
    private fun readCapped(input: InputStream): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        val buf = ByteArray(16 * 1024)
        var total = 0L
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            total += n
            if (total > EmojiCopyRules.MAX_IMAGE_BYTES) return null
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /**
     * Each set's signed 30030, as its author signed it: sent on to the person's own relays and kept in the vault, so
     * a set survives its author's relays (Tod's v1 scope). Never re-signed.
     */
    fun keepSetEvents(addresses: List<String>) {
        val events = emojiList.setEvents.value
        keepEvents(addresses.mapNotNull { events[it] })
    }

    /** [keepSetEvents] for events in hand (a set just added from Browse). Only signed 30030s, as they came. */
    fun keepEvents(events: List<NostrEvent>) {
        val picked = events.filter { it.kind == 30030 && it.sig.isNotEmpty() }
        if (picked.isEmpty()) return
        scope.launch {
            val owner = nostrService.ownerHexPubkey
            val own = runCatching { nostrService.ownListRelays(owner) }.getOrDefault(emptyList())
            val vault = configStore.config.value.localRelayURL("")
            for (e in picked) {
                if (own.isNotEmpty()) nostrService.publishFireAndForget(e, own)
                if (vault != null) runCatching { VaultSocket.publish(vault, e, ::signAuth) }
            }
        }
    }

    private suspend fun signAuth(challenge: String): NostrEvent? {
        val url = configStore.config.value.localRelayURL("") ?: return null
        return runCatching {
            nostrService.signEventAsync(
                kind = 22242,
                content = "",
                tags = listOf(listOf("relay", configStore.config.value.vaultAuthRelayTag(url)), listOf("challenge", challenge)),
                forceOwner = true,
            )
        }.getOrNull()
    }

    /** Copies are the owner's: another owner's file (a reset, a new vault) starts empty. */
    private fun ownerScoped(owner: String) {
        val reset = synchronized(lock) {
            if (disk.owner == owner) false else {
                disk = Disk(owner)
                true
            }
        }
        if (reset) {
            persist()
            publishState()
        }
    }

    private fun persist() {
        val text = synchronized(lock) { json.encodeToString(Disk.serializer(), disk) }
        runCatching {
            val temp = File(file.path + ".part")
            temp.writeText(text)
            temp.renameTo(file)
        }.onFailure { Log.w(TAG, "emoji copies not saved: ${it.message}") }
    }

    private fun publishState() {
        val (saved, dead, notes, hidden) = synchronized(lock) {
            val owner = nostrService.ownerHexPubkey
            val mine = if (disk.owner.isEmpty() || disk.owner == owner) disk else Disk()
            val savedMap = mine.saved.associateBy { it.sha256 }
            val plain = index.plainHashes
            val hidden = (index.hiddenFromMedia + mine.saved.filterNot { it.alsoMedia }.map { it.sha256 }) - plain
            Quad(savedMap, mine.dead, index.emojiNotes, hidden)
        }
        _saved.value = saved
        _dead.value = dead
        _notes.value = notes
        _hiddenFromMedia.value = hidden
        val config = configStore.config.value
        EmojiLocalCopies.update(saved.values, notes, config.relayDataDir?.let { File(it, config.blossomPath) })
    }

    private data class Quad(val a: Map<String, Saved>, val b: List<Dead>, val c: List<EmojiNote>, val d: Set<String>)

    private companion object {
        const val TAG = "EmojiVault"
    }
}
