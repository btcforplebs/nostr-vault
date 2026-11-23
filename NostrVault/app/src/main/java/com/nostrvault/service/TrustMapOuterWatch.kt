package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.TrustMapOuter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The globe's outer rings for the active account ([TrustMapOuter]), worked
 * out again only when the rank copy, the Discovery reach bar, your devices or
 * your blocks change, not on every frame of the globe. iOS
 * `Services/TrustMapOuterWatch.swift`.
 */
@Singleton
class TrustMapOuterWatch @Inject constructor(
    private val configStore: ConfigStore,
    private val reach: DiscoveryReachStore,
    /** Lazy: for the blocked keys, decoded once per list. */
    private val feedService: dagger.Lazy<FeedService>,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val _outer = MutableStateFlow(TrustMapOuter.NONE)
    val outer: StateFlow<TrustMapOuter> = _outer.asStateFlow()

    init {
        @OptIn(FlowPreview::class)
        combine(reach.copy, configStore.config) { _, _ -> }
            .debounce(150)
            .onEach { update() }
            .launchIn(scope)
    }

    private fun update() {
        val config = configStore.config.value
        _outer.value = TrustMapOuter.make(
            copy = reach.copy.value,
            bar = reach.bar(),
            desktopPaired = TrustMapOuter.desktopPaired(config.fipsMesh.devices.map { it.role }),
            hidden = feedService.get().blockedHexForActiveAccount(),
        )
    }
}
