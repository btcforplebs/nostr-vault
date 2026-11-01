package com.nostrvault.relay

import android.system.Os

/**
 * The Go runtime settings libhaven.so reads when it loads (dlopen time).
 *
 * Kept out of [HavenBridge] so main can set them without loading the
 * library: NostrVaultApp calls [ensure] on main, then loads the library on a
 * warm-up thread. bionic's setenv reallocates `environ` without a lock, so
 * it must not run on one thread while another reads the environment, which
 * is why the warm-up thread only loads. [HavenBridge] calls [ensure] too, so
 * any path that loads the library first still has these set; after the first
 * call it does nothing.
 */
object GoRuntimeEnv {

    private val applier = Applier { key, value -> Os.setenv(key, value, true) }

    fun ensure() = applier.ensure()

    /** Sets the values once through [set]; later calls do nothing. */
    internal class Applier(private val set: (String, String) -> Unit) {
        private var applied = false

        @Synchronized
        fun ensure() {
            if (applied) return
            values(RelayConfiguration.totalMemoryBytes()).forEach { (k, v) -> set(k, v) }
            applied = true
        }
    }

    internal fun values(physicalMemory: Long): List<Pair<String, String>> = listOf(
        // asyncpreemptoff=1 disables SIGURG-based goroutine preemption, which
        // conflicts with the JVM's signal handling on Android and causes heap
        // corruption ("s.allocCount != s.nelems", "bad pointer in Go heap").
        // cgocheck=0 disables the CGO pointer checks that can misfire when Go
        // heap objects contain mmap'd region boundaries.
        "GODEBUG" to "asyncpreemptoff=1,cgocheck=0,madvdontneed=1",
        // Go's soft memory limit, sized to this phone. A fixed 192 MiB was a
        // limit a populated vault's live heap reaches, and then the collector
        // runs back to back and the phone runs hot (iPhone #1007). The relay
        // sets the same value again at start (GO_MEM_LIMIT_MB, RelayConfiguration).
        "GOMEMLIMIT" to "${RelayConfiguration.phoneGoMemLimitMB(physicalMemory)}MiB",
        "GOGC" to "50",
    )
}
