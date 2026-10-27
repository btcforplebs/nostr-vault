package com.nostrvault.relay

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.nostrvault.data.local.ConfigStore
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent

/**
 * Auto-start the relay service when the device boots, and after an app
 * update: an update kills the process, and nothing else restarts the relay
 * until the app is next opened, so this vault and its mesh stay dark.
 * Honors the user's "Auto-start Relay" advanced setting, and never runs
 * before setup is finished.
 * The FIPS mesh, if left on, comes back with it (RelayForegroundService.restoreMesh),
 * which is why the config is loaded here first: the mesh's allowlist comes from it.
 */
class BootCompletedReceiver : BroadcastReceiver() {

    @EntryPoint
    @InstallIn(SingletonComponent::class)
    interface BootReceiverEntryPoint {
        fun configStore(): ConfigStore
    }

    companion object {
        private const val TAG = "BootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return

        val configStore = EntryPointAccessors
            .fromApplication(context.applicationContext, BootReceiverEntryPoint::class.java)
            .configStore()
        // Fresh process on boot or update — load persisted config before reading the flag.
        configStore.reload()
        val config = configStore.config.value
        // An external relay replaces the embedded one; there is nothing to boot.
        // Nor before setup is finished: a setup left half-way has no account
        // and no relay choice yet (it may be meant for Citrine).
        val autoStartEnabled = config.hasCompletedSetup && config.autoStartRelay && !config.useExternalRelay

        if (autoStartEnabled) {
            Log.i(TAG, "${intent.action} -- starting relay service")
            RelayForegroundService.start(context)
        } else {
            Log.d(TAG, "${intent.action} -- auto-start disabled, skipping")
        }
    }
}
