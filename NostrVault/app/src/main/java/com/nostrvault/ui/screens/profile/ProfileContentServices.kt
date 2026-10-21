package com.nostrvault.ui.screens.profile

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.BlossomService
import com.nostrvault.service.NostrService
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent

/**
 * The app singletons the profile's article cards and media tiles read on
 * their own (the author's name, your Blossom servers and what they hold), so
 * the page does not have to pass them down to every row.
 */
@EntryPoint
@InstallIn(SingletonComponent::class)
interface ProfileContentEntryPoint {
    fun nostrService(): NostrService
    fun blossomService(): BlossomService
    fun configStore(): ConfigStore
}

@Composable
internal fun rememberProfileContentServices(): ProfileContentEntryPoint {
    val context = LocalContext.current
    return remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, ProfileContentEntryPoint::class.java)
    }
}
