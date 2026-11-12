package com.nostrvault.service

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.atomic.AtomicInteger

/**
 * The rules one Auto-Mirror run keeps (Logen 2026-11-12, after the iPhone 18
 * signed 1,093 upload auths in half an hour and stored nothing new):
 *
 * 1. A photo the vault has is never downloaded: its hash is known first, from
 *    a hash-named link, the note's `imeta` `x`, or the link remembered from
 *    an earlier run ([AutoMirrorState]).
 * 2. One signature per run ([RunSignature]), shared by the server list and
 *    the note links.
 * 3. At most one run per 3 hours, counted from when a run starts and kept on
 *    disk, so a relaunch mid-run does not start another ([due]).
 * 4. At most [MAX_PER_RUN] downloads per run; the rest wait for the next run
 *    ([RunLimits]).
 *
 * iOS twin: Tal's (nv-tutorial).
 */
internal object AutoMirrorRules {
    const val EVERY_MS = 3L * 60 * 60 * 1000
    const val MAX_PER_RUN = 200

    /**
     * Stop starting downloads this long after the run signed: its upload auth
     * lasts an hour ([BlossomService.createAuthHeader]), and a second
     * signature is not allowed.
     */
    const val SIGNED_FOR_MS = 55L * 60 * 1000

    /** Whether an Auto-Mirror may start, given the last run's start. A clock set back doesn't hold it off for good. */
    fun due(lastStart: Long?, now: Long): Boolean =
        lastStart == null || now < lastStart || now - lastStart >= EVERY_MS

    /** `url` to `x` from the `imeta` tags of a note (NIP-92), lower-cased hashes only. */
    fun imetaHashes(tags: List<List<String>>): Map<String, String> {
        val out = HashMap<String, String>()
        for (tag in tags) {
            if (tag.firstOrNull() != "imeta") continue
            var url: String? = null
            var hash: String? = null
            for (field in tag.drop(1)) {
                when {
                    field.startsWith("url ") -> url = field.removePrefix("url ").trim()
                    field.startsWith("x ") -> hash = field.removePrefix("x ").trim().lowercase()
                }
            }
            if (url != null && hash != null && isHash(hash)) out[url] = hash
        }
        return out
    }

    fun isHash(s: String): Boolean = s.length == 64 && s.all { it in '0'..'9' || it in 'a'..'f' }
}

/**
 * One signature for the whole run: the first caller signs, every later one
 * gets the same answer, a failed one included (asking again would be a
 * second prompt). Never signed when nothing needs it.
 */
internal class RunSignature(private val sign: suspend () -> OwnVaultAuth?) {
    private val lock = Mutex()
    private var asked = false
    private var value: OwnVaultAuth? = null

    /** When the signature was made (null: not yet, or keyless/failed). */
    @Volatile var signedAt: Long? = null
        private set

    suspend fun get(now: () -> Long = System::currentTimeMillis): OwnVaultAuth? = lock.withLock {
        if (!asked) {
            asked = true
            value = sign()
            if (value is OwnVaultAuth.Signed) signedAt = now()
        }
        value
    }
}

/** What one run may still do: [cap] downloads, and none after its signature runs out. */
internal class RunLimits(
    val signature: RunSignature,
    val cap: Int = AutoMirrorRules.MAX_PER_RUN,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val taken = AtomicInteger(0)

    /** Downloads started so far. */
    val started: Int get() = taken.get()

    /** Claims one download; false once the run has had [cap], or its upload auth is nearly spent. */
    fun take(): Boolean {
        val signedAt = signature.signedAt
        if (signedAt != null && clock() - signedAt >= AutoMirrorRules.SIGNED_FOR_MS) return false
        while (true) {
            val n = taken.get()
            if (n >= cap) return false
            if (taken.compareAndSet(n, n + 1)) return true
        }
    }
}
