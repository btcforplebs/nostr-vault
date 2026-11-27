package com.nostrvault.service.cashu

import com.nostrvault.relay.HavenBridge

/**
 * The built-in Cashu wallet's engine calls (haven-go/wallet/bridge.go,
 * exported by haven-go/cashu_wallet_cshared.go, reached through
 * HavenBridgeJNI.c). Bytes in and out, so JSON with emoji crosses JNI as
 * plain UTF-8 (NewStringUTF would read it as modified UTF-8).
 */
interface CashuEngine {
    /** `{"ok":true,"result":{"handle":n}}` or an error reply. */
    fun open(path: String): ByteArray
    /** Blocks up to 2 minutes when it reaches a mint: never on the main thread. */
    fun call(handle: Int, method: String, args: String): ByteArray
    fun close(handle: Int)
}

object CashuNative : CashuEngine {
    @Volatile private var loaded = false

    /** JVM unit tests load a host build of libhaven (scripts/cashu-android-test.sh). */
    fun loadForTests(path: String) {
        System.load(path)
        loaded = true
    }

    private fun ensureLoaded() {
        if (loaded) return
        // HavenBridge loads libhaven.so, which carries these JNI symbols.
        if (!HavenBridge.isLoaded) throw CashuException("error", "The wallet engine isn't loaded.")
        loaded = true
    }

    override fun open(path: String): ByteArray {
        ensureLoaded()
        return openNative(path.toByteArray()) ?: ByteArray(0)
    }

    override fun call(handle: Int, method: String, args: String): ByteArray {
        ensureLoaded()
        return callNative(handle, method.toByteArray(), args.toByteArray()) ?: ByteArray(0)
    }

    override fun close(handle: Int) {
        if (loaded) closeNative(handle)
    }

    @JvmStatic private external fun openNative(path: ByteArray): ByteArray?
    @JvmStatic private external fun callNative(handle: Int, method: ByteArray, args: ByteArray): ByteArray?
    @JvmStatic private external fun closeNative(handle: Int)
}

/**
 * An engine refusal. [code] is the engine's stable name (`cashuErrCodes` in
 * haven-go/wallet/bridge.go); the message is its own text, for logs.
 */
class CashuException(val code: String, message: String) : Exception(message) {
    /**
     * The mint may have paid or may still pay: wait for the receipt and never
     * pay the same thing again from another mint. The engine keeps the spend
     * in its journal, so its recover finishes it either way.
     */
    val mayStillSettle: Boolean get() = code == "pending"

    /** Refused before any sats left the wallet. */
    val refusedBeforePaying: Boolean get() = code in BEFORE_PAYING

    /** For people. */
    val userMessage: String get() = when (code) {
        "pending" -> "Sent from your built-in wallet. The mint hasn't confirmed yet, so it may still pay."
        "not_enough" -> "Your built-in wallet doesn't have enough sats for this and the mint's fee."
        "busy" -> "Your built-in wallet is finishing an earlier payment. Try again in a moment."
        "no_change" -> "This mint can't give change, so paying from it would lose sats. Nothing was sent."
        "unknown_mint" -> "That mint isn't in your built-in wallet."
        "no_wallet" -> "There's no built-in wallet for this account on this device yet."
        else -> "Your built-in wallet couldn't pay: $message"
    }

    companion object {
        private val BEFORE_PAYING = setOf("not_enough", "busy", "no_change", "unknown_mint", "no_wallet", "bad_args")
        fun noWallet() = CashuException("no_wallet", "No built-in wallet for this account.")
        fun notEnough() = CashuException("not_enough", "Not enough sats in the built-in wallet.")
    }
}
