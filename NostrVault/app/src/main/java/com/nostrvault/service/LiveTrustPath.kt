package com.nostrvault.service

import com.nostrvault.data.model.TrustPath
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * One person's Trust Path that keeps up. It traces them again each time your
 * web changes ([TrustPathService.webChanged]), so following someone flips
 * their card to "You follow them" on every screen, not just the WOT tab.
 *
 * Port of iOS Services/LiveTrustPath.swift.
 */
class LiveTrustPath(
    private val trust: TrustPathService,
    private val scope: CoroutineScope,
) {
    private val _path = MutableStateFlow<TrustPath?>(null)
    /** Null while the first trace runs. */
    val path: StateFlow<TrustPath?> = _path.asStateFlow()

    /** Who [path] is for; null when stopped. */
    var author: String? = null
        private set
    private var job: Job? = null

    /** Null stops; the same author again does nothing. */
    fun track(author: String?) {
        if (author == this.author) return
        this.author = author
        job?.cancel()
        _path.value = null
        if (author == null) return
        job = scope.launch {
            // Latest only: a second follow mid-trace drops the stale answer.
            trust.webChanged.collectLatest { _path.value = trust.path(author) }
        }
    }
}
