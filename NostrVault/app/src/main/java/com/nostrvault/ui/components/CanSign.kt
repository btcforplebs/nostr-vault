package com.nostrvault.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.NostrService
import com.nostrvault.service.isReadOnlyAccount
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent

@EntryPoint
@InstallIn(SingletonComponent::class)
interface CanSignEntryPoint {
    fun nostrService(): NostrService
    fun configStore(): ConfigStore
}

/**
 * The active account can sign here: a key, Amber or a bunker. A read-only
 * sign-in gets no Post and no Edit Profile, as on iOS and the web. Read again
 * whenever the config changes (account switch, key added or removed).
 */
@Composable
fun rememberCanSign(): Boolean {
    val context = LocalContext.current
    val services = remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, CanSignEntryPoint::class.java)
    }
    val config by services.configStore().config.collectAsState()
    return remember(config) { !services.nostrService().isReadOnlyAccount() }
}
