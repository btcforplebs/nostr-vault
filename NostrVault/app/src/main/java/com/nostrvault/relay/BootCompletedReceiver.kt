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
 * Auto-start the relay service when the device boots.
 * Honors the user's "Auto-start Relay" advanced setting.
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
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        val configStore = EntryPointAccessors
            .fromApplication(context.applicationContext, BootReceiverEntryPoint::class.java)
            .configStore()
        // Fresh process on boot — load persisted config before reading the flag.
        configStore.reload()
        val config = configStore.config.value
        // An external relay replaces the embedded one; there is nothing to boot.
        val autoStartEnabled = config.autoStartRelay && !config.useExternalRelay

        if (autoStartEnabled) {
            Log.i(TAG, "Boot completed -- starting relay service")
            RelayForegroundService.start(context)
        } else {
            Log.d(TAG, "Boot completed -- auto-start disabled, skipping")
        }
    }
}
