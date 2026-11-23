package com.nostrvault.service

import android.os.Handler
import android.os.Looper
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.DiscoveryReach
import com.nostrvault.data.model.DistantPostAuthors
import com.nostrvault.data.model.TrustRankCopy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The active account's rank copy and who the Discovery reach bar lets in
 * ([DiscoveryReach]). Read again when the account or the bar changes, when
 * the app comes back to the front and when Settings › Feed opens (the mesh
 * catch-up rewrites the file while the app is away); the feed recomputes
 * whenever the admitted people change. iOS `DiscoveryReachStore.swift`.
 */
@Singleton
class DiscoveryReachStore @Inject constructor(
    private val configStore: ConfigStore,
    private val copies: TrustRankCopyStore,
    /** Lazy: FeedService holds this store, and this store asks it to recompute. */
    private val feedService: dagger.Lazy<FeedService>,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val _copy = MutableStateFlow<TrustRankCopy?>(null)
    val copy: StateFlow<TrustRankCopy?> = _copy.asStateFlow()

    /** Empty with no copy. Read by the feed filter on any thread. */
    @Volatile var admitted: DiscoveryReach.Admitted = DiscoveryReach.Admitted.NONE
        private set

    /** The admitted distant people Discover asks the local feed store for ([DistantPostAuthors]), empty with no copy. */
    @Volatile var localDistantAuthors: List<String> = emptyList()
        private set

    private var load: Job? = null

    init {
        scope.launch { configStore.activeAccountHexPubkey.collect { reload(it) } }
        scope.launch {
            configStore.config.map { it.discoveryBar }.distinctUntilChanged().drop(1).collect { apply(it) }
        }
        // The process lifecycle only takes observers on the main thread.
        Handler(Looper.getMainLooper()).post {
            ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
                override fun onStart(owner: LifecycleOwner) = refresh()
            })
        }
    }

    /** The bar in use, null with no copy. */
    fun bar(): Double? = _copy.value?.let { DiscoveryReach.bar(configStore.config.value.discoveryBar, it) }

    /** Reads the file again (cheap when it has not changed). */
    fun refresh() = reload(configStore.activeAccountHexPubkey.value)

    /** Saves [bar] (null when it is the file's starting bar). */
    fun save(bar: Double) {
        val copy = _copy.value ?: return
        configStore.update { it.copy(discoveryBar = DiscoveryReach.saved(bar, copy)) }
    }

    private fun reload(me: String) {
        load?.cancel()
        // Another account's people never judge this one's feed, not even while its own file loads.
        if (_copy.value?.let { it.account != me } == true) {
            _copy.value = null
            apply(null)
        }
        load = scope.launch {
            val copy = copies.copyFor(me)
            // The store hands back the same copy while the file is unchanged; compare the header, not every row.
            val held = _copy.value
            if (copy?.account != held?.account || copy?.builtAt != held?.builtAt || copy?.people?.size != held?.people?.size) {
                _copy.value = copy
            }
            apply(configStore.config.value.discoveryBar)
        }
    }

    private fun apply(saved: Double?) {
        val next = _copy.value?.let { DiscoveryReach.admitted(it, DiscoveryReach.bar(saved, it)) } ?: DiscoveryReach.Admitted.NONE
        val feed = feedService.get()
        if (next != admitted) {
            admitted = next
            feed.recomputeFilteredNotes()
        }
        val authors = DistantPostAuthors.pick(next.distant, _copy.value, feed.blockedHexForActiveAccount())
        if (authors == localDistantAuthors) return
        localDistantAuthors = authors
        // The live request to the local store carries the old list until it is
        // sent again: a moved bar, a re-read file, or a copy that loaded after
        // Discover's first request went out.
        feed.resendDistantPostsRequest()
    }
}
