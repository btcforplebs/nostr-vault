package com.nostrvault.service.shareportal

import android.content.Context
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.NostrService
import com.nostrvault.shareportal.ShareAccountsSnapshot
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Keeps [ShareAccountsSnapshot] current for the share sheet's "post as" line:
 * the device's accounts with their names and pictures, never a key. Twin: the
 * iOS app writes NVShareAccountsSnapshot on scene activation.
 */
@Singleton
class ShareAccountsPublisher @Inject constructor(
    @ApplicationContext private val context: Context,
    private val configStore: ConfigStore,
    private val nostrService: NostrService,
) {
    @OptIn(FlowPreview::class)
    fun start(scope: CoroutineScope) {
        scope.launch(Dispatchers.IO) {
            combine(configStore.config, nostrService.profiles) { config, profiles ->
                if (!config.hasCompletedSetup || config.ownerNpub.isBlank()) return@combine null
                ShareAccountsSnapshot(
                    active = config.activeOrOwnerNpub(),
                    accounts = config.allAccountNpubs().filter { it.isNotBlank() }.distinct().map { npub ->
                        // bech32 decoding is native; before the library is up, names wait.
                        val profile = if (HavenBridge.isLoaded) nostrService.npubToHex(npub)?.let { profiles[it] } else null
                        ShareAccountsSnapshot.Account(
                            npub = npub,
                            name = profile?.bestName?.takeIf { it.isNotBlank() } ?: (npub.take(12) + "…"),
                            picture = profile?.pictureURL?.takeIf { it.startsWith("https://") },
                        )
                    },
                )
            }
                .distinctUntilChanged()
                .debounce(1_000)
                .flowOn(Dispatchers.Default)
                .collect { snapshot ->
                    val file = ShareAccountsSnapshot.file(context)
                    if (snapshot == null) file.delete() else ShareAccountsSnapshot.write(file, snapshot)
                }
        }
    }
}
