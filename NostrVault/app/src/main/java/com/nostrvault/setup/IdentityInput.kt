package com.nostrvault.setup

/**
 * What someone pasted or scanned into the "I already use Nostr" key field.
 * One field takes everything, and what it holds decides the mode: a public
 * key or name@domain is read-only, a private key or a signer app can post.
 * Same as iOS `IdentityInput`.
 *
 * Recognises the shape only. The caller still checks a key's checksum and
 * resolves name@domain over the network.
 */
sealed class IdentityInput {
    data object Empty : IdentityInput()
    /** `npub1…`: read-only. */
    data class PublicKey(val key: String) : IdentityInput()
    /** `name@domain` or a bare `domain.tld`: resolves to a public key, read-only. */
    data class Nip05(val name: String) : IdentityInput()
    /** `nsec1…`: can post. */
    data class SecretKey(val key: String) : IdentityInput()
    /** `ncryptsec1…`: a password-protected private key (NIP-49), can post. */
    data class EncryptedSecretKey(val key: String) : IdentityInput()
    /** `bunker://<signer pubkey>?relay=…`: a signer app (NIP-46), can post. */
    data class RemoteSigner(val uri: String) : IdentityInput()
    /** 64 hex characters. Refused: it could be a public or a private key,
     *  and guessing wrong would show someone's private key as their identity. */
    data object HexKey : IdentityInput()
    data object Unrecognised : IdentityInput()

    /** Whether this identity can sign: post, DM and zap. */
    val canPost: Boolean
        get() = this is SecretKey || this is EncryptedSecretKey || this is RemoteSigner

    /** The setup mode it leads to, as stored in `HavenConfig.setupMode`.
     *  Null while the field isn't usable yet. */
    val setupMode: String?
        get() = when (this) {
            is PublicKey, is Nip05 -> "browse"
            is SecretKey, is EncryptedSecretKey, is RemoteSigner -> "full"
            else -> null
        }

    /** One plain line, so nobody needs the words "browse mode" or "nsec". */
    val hint: String?
        get() = when (this) {
            Empty -> null
            is PublicKey, is Nip05 -> "You can read everything. Add your key later in Settings to post."
            is SecretKey, is EncryptedSecretKey -> "You can post, message and zap. Your key stays on this device."
            is RemoteSigner -> "You can post, message and zap. Your signer app approves each one."
            HexKey -> "Paste the npub or nsec version of this key."
            Unrecognised -> "Paste an npub, name@domain, nsec, or a bunker:// link."
        }

    companion object {
        fun parse(raw: String): IdentityInput {
            var text = raw.trim()
            // QR codes and links often carry the NIP-21 scheme.
            if (text.lowercase().startsWith("nostr:")) text = text.drop(6)
            val lower = text.lowercase()
            return when {
                text.isEmpty() -> Empty
                lower.startsWith("bunker:") -> if (isBunkerUri(text)) RemoteSigner(text) else Unrecognised
                lower.startsWith("nsec1") -> SecretKey(lower)
                lower.startsWith("ncryptsec1") -> EncryptedSecretKey(lower)
                lower.startsWith("npub1") -> PublicKey(lower)
                lower.length == 64 && lower.all { it in '0'..'9' || it in 'a'..'f' } -> HexKey
                looksLikeNip05(lower) -> Nip05(lower)
                else -> Unrecognised
            }
        }

        /** `bunker://` + a 64-hex signer pubkey + at least one `relay=`. */
        private fun isBunkerUri(text: String): Boolean {
            val body = text.substringAfter("://", "")
            val pubkey = body.substringBefore("?").trimEnd('/')
            val query = body.substringAfter("?", "")
            return pubkey.length == 64 &&
                pubkey.lowercase().all { it in '0'..'9' || it in 'a'..'f' } &&
                query.split("&").any { it.startsWith("relay=") && it.length > 6 }
        }

        /** user@domain.tld, or a bare domain.tld (NIP-05 `_@domain`). */
        private fun looksLikeNip05(text: String): Boolean {
            if (text.contains(" ") || text.contains("/") || !text.contains(".")) return false
            val parts = text.split("@")
            if (parts.size > 2) return false
            if (parts.size == 2 && parts[0].isEmpty()) return false
            val domain = parts.last()
            return domain.contains(".") && !domain.startsWith(".") && !domain.endsWith(".")
        }
    }
}
