package com.nostrvault.relay

import android.util.Log
import kotlinx.serialization.json.JsonObject
import java.io.File
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Signature checks, each event once.
 *
 * The same note reaches the app many times: from every relay that has it,
 * and again each time a subscription replays history (DMs on every
 * reconnect, the WOT tab's engagement on every open). [HavenBridge.verifyEvent]
 * is a JNI call into Go, a JSON parse and a Schnorr check each time.
 *
 * Only passes are remembered, keyed on everything the check reads: id,
 * pubkey, created_at, kind, tags, content and sig. A copy that differs in any
 * of them (a forged one reusing a real id and signature) has another key and
 * is checked in full; a failure is never remembered, so a bad signature is
 * refused every time. Go's relay keeps its own once-per-event cache
 * (haven-go go-nostr); this one covers events Kotlin reads straight from
 * sockets.
 *
 * The passes are also kept on disk ([attach]): after a restart the relays send
 * again the profiles, relay lists and notes the last run already checked, and
 * checking them again was most of the app's CPU in its first 20 s (perf round
 * 3, 2026-11-18). The file holds only the keys above, never an event, and
 * only for events that passed; a key is the hash of every checked field, so a
 * changed or forged copy never matches one. It lives in noBackupFilesDir, so
 * a backup restored from elsewhere cannot bring keys this install never
 * checked.
 */
object VerifiedEvents {
    private const val MAX = 20_000
    private val FIELDS = listOf("id", "pubkey", "created_at", "kind", "tags", "content", "sig")

    private val passed = object : LinkedHashMap<ByteBuffer, Unit>(1024, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<ByteBuffer, Unit>?) = size > MAX
    }

    /** Whether [event]'s id and signature check out; [check] runs at most once per passing event. */
    fun verify(event: JsonObject, check: (String) -> Boolean = HavenBridge::verifyEvent): Boolean {
        val key = key(event) ?: return false
        if (synchronized(passed) { passed[key] != null }) return true
        if (!check(event.toString())) return false
        synchronized(passed) { passed[key] = Unit }
        scheduleSave()
        return true
    }

    // MARK: kept on disk

    private const val FILE_NAME = "verified_events.bin"
    private val MAGIC = "NVVE0001".toByteArray(Charsets.US_ASCII)
    private const val KEY_BYTES = 32
    private const val SAVE_DELAY_S = 5L

    private var file: File? = null // guarded by passed
    private val saveQueued = AtomicBoolean(false)
    private val saver = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "nv-verified-save").apply { isDaemon = true }
    }

    /** Loads the last run's passes from [dir] in the background, then keeps saving new ones there. */
    fun attach(dir: File) {
        saver.execute { load(File(dir, FILE_NAME)) }
    }

    /** [attach], loading on the caller's thread. */
    internal fun attachNowForTest(dir: File) = load(File(dir, FILE_NAME))

    private fun load(f: File) {
        val keys = runCatching { readKeys(f) }.getOrElse {
            Log.w("VerifiedEvents", "verified-events file unreadable, starting empty", it)
            emptyList()
        }
        synchronized(passed) {
            // What this run already passed is newer than the file: it goes last.
            val current = passed.keys.toList()
            passed.clear()
            for (k in keys) passed[k] = Unit
            for (k in current) passed[k] = Unit
            file = f
        }
        if (keys.isEmpty()) scheduleSave()
    }

    /** The file's keys, oldest first; empty for a missing, foreign or damaged file. */
    internal fun readKeys(f: File): List<ByteBuffer> {
        if (!f.isFile) return emptyList()
        val bytes = f.readBytes()
        if (bytes.size < MAGIC.size || !bytes.copyOfRange(0, MAGIC.size).contentEquals(MAGIC)) return emptyList()
        // Whole keys only, aligned from the header (a file cut short loses its last key).
        val whole = (bytes.size - MAGIC.size) / KEY_BYTES
        val n = minOf(whole, MAX)
        val start = MAGIC.size + (whole - n) * KEY_BYTES
        return List(n) { i -> ByteBuffer.wrap(bytes.copyOfRange(start + i * KEY_BYTES, start + (i + 1) * KEY_BYTES)) }
    }

    private fun scheduleSave() {
        if (synchronized(passed) { file } == null) return
        if (saveQueued.compareAndSet(false, true)) {
            saver.schedule({ saveQueued.set(false); saveNow() }, SAVE_DELAY_S, TimeUnit.SECONDS)
        }
    }

    /** Writes every pass, oldest first, through a temp file so a crash never leaves half a file. */
    internal fun saveNow() {
        val (f, keys) = synchronized(passed) { (file ?: return) to passed.keys.toList() }
        runCatching {
            val tmp = File(f.parentFile, "$FILE_NAME.tmp")
            tmp.outputStream().buffered().use { out ->
                out.write(MAGIC)
                for (k in keys) out.write(k.array(), k.arrayOffset(), KEY_BYTES)
            }
            if (!tmp.renameTo(f)) error("rename failed")
        }.onFailure { Log.w("VerifiedEvents", "verified-events save failed", it) }
    }

    /** [verify] for an event as relay JSON text, parsed once here. */
    fun verify(eventJson: String, check: (String) -> Boolean = HavenBridge::verifyEvent): Boolean {
        val event = runCatching {
            kotlinx.serialization.json.Json.parseToJsonElement(eventJson) as? JsonObject
        }.getOrNull() ?: return false
        return verify(event, check)
    }

    /** SHA-256 over the checked fields, each with its length; null when one is missing. */
    internal fun key(event: JsonObject): ByteBuffer? {
        val digest = MessageDigest.getInstance("SHA-256")
        for (field in FIELDS) {
            val bytes = (event[field] ?: return null).toString().toByteArray(Charsets.UTF_8)
            digest.update(ByteBuffer.allocate(4).putInt(bytes.size).array())
            digest.update(bytes)
        }
        return ByteBuffer.wrap(digest.digest())
    }

    internal fun clearForTest() = synchronized(passed) {
        passed.clear()
        file = null
    }
}
