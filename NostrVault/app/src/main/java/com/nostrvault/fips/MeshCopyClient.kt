package com.nostrvault.fips

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * B's start of the zip mesh copy (docs/MESH_COPY_V2_CONTRACT.md §2-§3): one owner-signed NIP-98 `POST
 * /copy/v2/start` through the other vault's kept link ([OtherVaultLink]), then the manifest, polled until A has
 * built it, checked, and held against this device's free space. The chunks are the engine's to fetch.
 *
 * Neither the copy token nor the link's own path is ever logged.
 */
class MeshCopyClient(
    private val http: OkHttpClient = defaultHttp,
    private val pollEveryMs: Long = POLL_EVERY_MS,
    private val buildWaitMs: Long = BUILD_WAIT_MS,
) {
    sealed interface Result {
        /** A built the copy and it fits here: the engine takes it from [started]. */
        data class Ready(val started: MeshCopyV2.Started, val manifest: MeshCopyV2.Manifest) : Result
        /** A answers 404 on the start: it has no zip copy yet (an older app), so the relays carry the copy. */
        data object NotServed : Result
        /** A contract error ([MeshCopyV2.ERROR_CODES]); [line] is what the screen says (may be empty). */
        data class Failed(val code: String, val line: String) : Result
    }

    /**
     * [linkWs]: the kept link (`ws://127.0.0.1:<port>/<link token>`). [authHeader]: the owner's `Nostr <base64>`
     * header for the given NIP-98 tags, or null when the signer said no.
     */
    suspend fun start(
        linkWs: String,
        ownerHex: String,
        name: String,
        freeBytes: () -> Long,
        authHeader: suspend (List<List<String>>) -> String?,
    ): Result {
        val (base, prefix) = MeshCopyV2.splitLink(linkWs) ?: return fail("unreachable", name)
        val auth = authHeader(MeshCopyV2.startTags(base)) ?: return fail("auth_refused", name)
        val started = when (val r = post(base + prefix + MeshCopyV2.START_PATH, auth)) {
            is Http.Ok -> MeshCopyV2.parseStart(r.body) ?: return fail("bad_manifest", name)
            is Http.Status -> return if (r.code == 404) Result.NotServed else fail(MeshCopyV2.errorForHttp(r.code) ?: "bad_manifest", name)
            Http.Down -> return fail("unreachable", name)
        }
        val manifestUrl = "$base$prefix/copy/v2/${started.id}"
        val until = System.currentTimeMillis() + buildWaitMs
        while (true) {
            val code = when (val r = get(manifestUrl, "Bearer ${started.token}")) {
                is Http.Ok -> {
                    val m = MeshCopyV2.parseManifest(r.body) ?: return fail("bad_manifest", name)
                    when (val err = MeshCopyV2.manifestError(m, ownerHex)) {
                        null -> return MeshCopyV2.spaceLine(m, freeBytes(), name)?.let { Result.Failed("needs_space", it) }
                            ?: Result.Ready(started, m)
                        else -> err
                    }
                }
                is Http.Status -> MeshCopyV2.errorForHttp(r.code) ?: "bad_manifest"
                Http.Down -> "unreachable"
            }
            if (MeshCopyV2.action(code) != MeshCopyV2.Action.WAIT) return fail(code, name)
            if (System.currentTimeMillis() >= until) return fail("unreachable", name)
            delay(pollEveryMs)
        }
    }

    private fun fail(code: String, name: String) = Result.Failed(code, MeshCopyV2.errorLine(code, name))

    private sealed interface Http {
        data class Ok(val body: String) : Http
        data class Status(val code: Int) : Http
        data object Down : Http
    }

    private suspend fun post(url: String, auth: String) =
        call(Request.Builder().url(url).header("Authorization", auth).post(ByteArray(0).toRequestBody(JSON)).build())

    private suspend fun get(url: String, auth: String) =
        call(Request.Builder().url(url).header("Authorization", auth).get().build())

    // One request per connection: the kept link takes its secret off the first request line only.
    private suspend fun call(req: Request): Http = withContext(Dispatchers.IO) {
        try {
            http.newCall(req.newBuilder().header("Connection", "close").build()).execute().use { r ->
                if (r.isSuccessful) Http.Ok(r.body?.string().orEmpty()) else Http.Status(r.code)
            }
        } catch (_: IOException) {
            Http.Down
        }
    }

    companion object {
        const val POLL_EVERY_MS = 2_000L
        /** How long B waits for A to build before it reads A as unreachable (resumes on the next reconnect). */
        const val BUILD_WAIT_MS = 30 * 60 * 1000L
        private val JSON = "application/json".toMediaType()
        private val defaultHttp by lazy {
            OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS).build()
        }
    }
}
