package com.nostrvault.fips

import okhttp3.Request

/**
 * "Is this blob on the vault yet?": HEAD /<sha256> on its mesh door, signed by the owner. Since #1018 the
 * door serves a blob that no posted note names only to the owner's signed kind 24242 "get" (haven-go
 * meshBlobRejectGet); unsigned, the check answers 404 and the phone sends a photo the vault already has.
 * iOS HomeVaultLogic.vaultCheckAuthTags / vaultCheckRequest (a652aeb7). Pure for the tests.
 */
internal object VaultCheck {
    /** How long one signed check is good for. */
    const val AUTH_LIFETIME_S = 300L

    /** Tags of the owner's kind 24242 "get" for [sha256]: khatru checks the type, the hash and the expiry. */
    fun authTags(sha256: String, nowSeconds: Long): List<List<String>> = listOf(
        listOf("t", "get"),
        listOf("x", sha256),
        listOf("expiration", (nowSeconds + AUTH_LIFETIME_S).toString()),
    )

    /** HEAD [base]/[sha256], signed when [authBase64] is given; unsigned is what a failed signer leaves. */
    fun request(base: String, sha256: String, authBase64: String?): Request =
        Request.Builder().url("$base/$sha256").head()
            .apply { if (authBase64 != null) header("Authorization", "Nostr $authBase64") }
            .build()
}
