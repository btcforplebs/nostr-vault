package com.nostrvault.fips

import okhttp3.Request

/**
 * "Is this blob on the vault yet?": HEAD /<sha256>, signed by this phone's mesh key (never the account key).
 * Since #1050 the mesh door answers HEAD with GET's rules: an unposted blob only for the owner's
 * signed kind 24242 "get" (haven-go mesh_head.go; a paired device's mesh-key "get" counts), so a sender the vault does not list among its
 * devices got 404 and sent the photo again. My Devices reach the relay port, which needs no auth.
 * iOS HomeVaultLogic.vaultCheckAuthTags / vaultCheckRequest (a652aeb7). Pure for the tests.
 */
internal object VaultCheck {
    /** How long one signed check is good for. */
    const val AUTH_LIFETIME_S = 300L

    /** HEAD [base]/[sha256], signed when [authBase64] is given; unsigned is what a failed signer leaves. */
    fun request(base: String, sha256: String, authBase64: String?): Request =
        Request.Builder().url("$base/$sha256").head()
            .apply { if (authBase64 != null) header("Authorization", "Nostr $authBase64") }
            .build()
}
