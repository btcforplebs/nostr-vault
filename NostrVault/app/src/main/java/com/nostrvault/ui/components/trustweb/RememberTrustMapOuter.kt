package com.nostrvault.ui.components

import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import com.nostrvault.data.model.TrustMapOuter
import com.nostrvault.service.DiscoveryReachStore
import com.nostrvault.service.TrustMapOuterWatch
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent

@EntryPoint
@InstallIn(SingletonComponent::class)
interface GlobeOuterRingsEntryPoint {
    fun trustMapOuterWatch(): TrustMapOuterWatch
    fun discoveryReachStore(): DiscoveryReachStore
}

/** The rings for your own globe, kept up to date ([TrustMapOuterWatch]). */
@Composable
internal fun rememberTrustMapOuter(): TrustMapOuter {
    val context = LocalContext.current
    val watch = remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, GlobeOuterRingsEntryPoint::class.java).trustMapOuterWatch()
    }
    val outer by watch.outer.collectAsState()
    return outer
}
