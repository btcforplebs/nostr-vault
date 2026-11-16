package com.nostrvault.service.translate

import android.util.Log

/**
 * libnvtranslate.so (NostrVault/translate-native): Mozilla's Bergamot engine
 * and fastText language ID. Handles are native pointers; whoever creates one
 * frees it. Translation calls must come from one thread at a time.
 */
internal object BergamotNative {

    /**
     * False when the .so is missing or won't load; Translate then stays
     * hidden. Loaded when this object is first touched, so no native call can
     * run before the library is in.
     */
    val isAvailable: Boolean = runCatching { System.loadLibrary("nvtranslate") }
        .onFailure { Log.w("BergamotNative", "libnvtranslate not loaded", it) }
        .isSuccess

    /**
     * The one Bergamot service for the process. Bergamot registers global
     * loggers when a service is made, so a second one would throw; it lives
     * as long as the app. Use from one thread at a time.
     */
    val service: Long by lazy { createService() }

    @JvmStatic private external fun createService(): Long

    /** [config] is Bergamot YAML ([MozillaModelCatalog.bergamotConfig]). */
    @JvmStatic external fun loadModel(config: String): Long
    @JvmStatic external fun freeModel(model: Long)

    @JvmStatic external fun translate(service: Long, model: Long, texts: Array<String>): Array<String>

    /** [first] into English, then [second] out of it. */
    @JvmStatic external fun pivot(service: Long, first: Long, second: Long, texts: Array<String>): Array<String>

    @JvmStatic external fun loadLanguageId(path: String): Long
    @JvmStatic external fun freeLanguageId(model: Long)

    /** "de 0.97", or "" when there is no guess. */
    @JvmStatic external fun identify(model: Long, text: String): String
}
