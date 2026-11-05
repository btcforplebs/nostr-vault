package com.nostrvault.fips

import android.content.Context
import android.os.StatFs
import android.util.Base64
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.EventPublisher
import com.nostrvault.service.NostrService
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.File
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * B, on any link (setup's "Copy from my other vault" and Vault › Your devices › Add): dials the other vault, signs
 * the one start, waits for A's manifest and the free-space check, and hands the copy to the engine. The engine's
 * `COPY` lines come back through [onLogLine] as [progress]. Twin of the Apple lane's start (docs/MESH_COPY_V2_CONTRACT.md).
 */
@Singleton
class MeshCopyStarter internal constructor(
    private val dataDir: () -> File,
    private val link: OtherVaultLink,
    private val ownerHex: () -> String?,
    private val sign: suspend (List<List<String>>) -> String?,
    private val client: MeshCopyClient,
    private val freeBytes: (File) -> Long,
) {
    @Inject constructor(
        @ApplicationContext context: Context,
        configStore: ConfigStore,
        nostrService: NostrService,
        link: OtherVaultLink,
    ) : this(
        dataDir = { configStore.config.value.relayDataDir?.let(::File) ?: File(context.filesDir, "relay_data") },
        link = link,
        ownerHex = { configStore.config.value.ownerNpub.takeIf { it.startsWith("npub1") }?.let(nostrService::npubToHex) },
        sign = { tags -> signStart(nostrService, tags) },
        client = MeshCopyClient(),
        freeBytes = { dir -> runCatching { StatFs(dir.apply { mkdirs() }.absolutePath).availableBytes }.getOrDefault(0L) },
    )

    private val _progress = MutableStateFlow<MeshCopyV2.Line?>(null)
    /** The engine's newest `COPY` line, or null before any. */
    val progress: StateFlow<MeshCopyV2.Line?> = _progress.asStateFlow()

    /** A relay log line: a `COPY` line becomes [progress] (and is returned). */
    fun onLogLine(raw: String): MeshCopyV2.Line? {
        if (!raw.contains("COPY ")) return null
        return MeshCopyV2.parseLine(raw)?.also { _progress.value = it }
    }

    /**
     * The other vault's kept address once it answers, dialed every [OtherVaultCopy.DIAL_RETRY_S] for up to
     * [OtherVaultCopy.DIAL_WINDOW_S] (a phone just linked is often still finding the other one), else null.
     */
    suspend fun dial(meshNpub: String, nowS: () -> Long = { System.currentTimeMillis() / 1000 }): String? {
        val startedAt = nowS()
        while (true) {
            val url = withContext(Dispatchers.IO) { link.open(meshNpub)?.takeIf(::answers) }
            if (url != null) return url
            if (!OtherVaultCopy.dialsAgain(startedAt, nowS())) return null
            delay(OtherVaultCopy.DIAL_RETRY_S * 1000)
        }
    }

    /**
     * The start on [linkWs], from the other device called [name]. On [MeshCopyClient.Result.Ready] the copy is the
     * engine's ([HANDOFF_FILE]) and [progress] follows it.
     */
    suspend fun start(linkWs: String, name: String): MeshCopyClient.Result {
        val owner = ownerHex() ?: return MeshCopyClient.Result.Failed("auth_refused", MeshCopyV2.errorLine("auth_refused", name))
        _progress.value = null
        val dir = dataDir()
        val r = client.start(linkWs, owner, name, { freeBytes(dir) }, sign)
        if (r is MeshCopyClient.Result.Ready) withContext(Dispatchers.IO) { handOff(dir, linkWs, r) }
        Log.i(TAG, "Mesh copy start: ${outcome(r)}")
        return r
    }

    /** The outcome without the token, the id or the address. */
    private fun outcome(r: MeshCopyClient.Result) = when (r) {
        is MeshCopyClient.Result.Ready -> "ready"
        MeshCopyClient.Result.NotServed -> "not served"
        is MeshCopyClient.Result.Failed -> r.code
    }

    private fun answers(wsUrl: String): Boolean = runCatching {
        val request = okhttp3.Request.Builder().url(wsUrl.replaceFirst("ws://", "http://"))
            .header("Accept", "application/nostr+json").header("Connection", "close").build()
        probe.newCall(request).execute().use { it.isSuccessful }
    }.getOrDefault(false)

    private val probe by lazy {
        okhttp3.OkHttpClient.Builder()
            .connectTimeout(PROBE_TIMEOUT_S, TimeUnit.SECONDS)
            .readTimeout(PROBE_TIMEOUT_S, TimeUnit.SECONDS)
            .build()
    }

    companion object {
        private const val TAG = "MeshCopy"
        private const val PROBE_TIMEOUT_S = 8L

        /** What the engine's copy job reads in the data dir: the link, the copy id and its token. Owner-only. */
        const val HANDOFF_FILE = "copy-start.json"

        /** Written whole (a `.partial` renamed) and 0600: the token is a bearer for A's vault. */
        internal fun handOff(dir: File, linkWs: String, ready: MeshCopyClient.Result.Ready) {
            dir.mkdirs()
            val body = JsonObject(
                linkedMapOf(
                    "v" to JsonPrimitive(1),
                    "link" to JsonPrimitive(linkWs),
                    "id" to JsonPrimitive(ready.started.id),
                    "token" to JsonPrimitive(ready.started.token),
                    "zip_key" to JsonPrimitive(ready.manifest.zipKey),
                ),
            ).toString()
            val tmp = File(dir, "$HANDOFF_FILE.partial")
            tmp.delete()
            tmp.createNewFile()
            ownerOnly(tmp)
            tmp.writeText(body)
            if (!tmp.renameTo(File(dir, HANDOFF_FILE))) {
                tmp.delete()
                throw java.io.IOException("copy hand-off not written")
            }
        }

        internal fun ownerOnly(f: File) {
            f.setReadable(false, false); f.setReadable(true, true)
            f.setWritable(false, false); f.setWritable(true, true)
            f.setExecutable(false, false)
        }

        /** The owner's `Nostr <base64>` header for the start; null when the signer says no. */
        private suspend fun signStart(nostr: NostrService, tags: List<List<String>>): String? {
            val ev = try {
                nostr.signEventAsync(kind = MeshCopyV2.NIP98_KIND, content = "", tags = tags, forceOwner = true)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                null
            } ?: return null
            return "Nostr " + Base64.encodeToString(EventPublisher.serializeSignedEvent(ev).toByteArray(), Base64.NO_WRAP)
        }
    }
}
