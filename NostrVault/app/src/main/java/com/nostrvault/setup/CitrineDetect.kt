package com.nostrvault.setup

import android.content.pm.PackageManager

/**
 * Whether Citrine, the relay app, is on this phone. Setup asks Citrine users
 * one question, Nostr Vault or Citrine, so they don't end up keeping every
 * note twice. Citrine listens on [RELAY_URL] unless its owner changed the port.
 * The package needs a `<queries>` entry in the manifest to be visible.
 */
object CitrineDetect {
    const val PACKAGE = "com.greenart7c3.citrine"
    const val RELAY_URL = "ws://127.0.0.1:4869"

    fun isInstalled(packageManager: PackageManager): Boolean =
        isInstalled { packageManager.getPackageInfo(it, 0) }

    /** [lookup] throws [PackageManager.NameNotFoundException] for a missing package. */
    internal fun isInstalled(lookup: (String) -> Any?): Boolean =
        try {
            lookup(PACKAGE)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        } catch (_: RuntimeException) {
            false
        }
}
