package com.nostrvault.service

import android.util.Log
import com.nostrvault.data.local.ConfigStore
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Manages push notification registration with a remote push server.
 *
 * When a device token is available (from FCM once configured) and
 * a push server URL is set, this service registers the token + pubkey
 * + notification preferences with the server. Re-registers automatically
 * on preference or account changes.
 *
 * The actual FirebaseMessagingService should be added when the Firebase
 * dependency is enabled (google-services.json + build.gradle).
 */
@Singleton
class PushNotificationService @Inject constructor(
    private val configStore: ConfigStore,
) {
    companion object {
        private const val TAG = "PushNotification"
    }

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    private val _deviceToken = MutableStateFlow<String?>(null)
    val deviceToken: StateFlow<String?> = _deviceToken.asStateFlow()

    private val _registrationStatus = MutableStateFlow(RegistrationStatus.UNREGISTERED)
    val registrationStatus: StateFlow<RegistrationStatus> = _registrationStatus.asStateFlow()

    init {
        // Re-register when config changes
        scope.launch {
            configStore.config
                .map { it.enablePushNotifications }
                .distinctUntilChanged()
                .collect { enabled ->
                    if (enabled) {
                        registerIfReady()
                    } else {
                        unregister()
                    }
                }
        }
    }

    /**
     * Called when FCM delivers a new device token.
     */
    fun onNewToken(token: String) {
        _deviceToken.value = token
        registerIfReady()
    }

    /**
     * Attempt to register with the push server if all prerequisites are met.
     */
    fun registerIfReady() {
        val config = configStore.config.value
        val token = _deviceToken.value
        val serverUrl = config.pushServerURL.trim()

        if (!config.enablePushNotifications || token.isNullOrEmpty() || serverUrl.isEmpty()) {
            return
        }

        _registrationStatus.value = RegistrationStatus.REGISTERING

        scope.launch {
            try {
                // Register every account with its own per-account preferences.
                val accounts = config.allAccountNpubs()
                    .mapNotNull { npub -> com.nostrvault.relay.HavenBridge.decodeNpub(npub)?.let { npub to it } }
                if (accounts.isEmpty()) {
                    _registrationStatus.value = RegistrationStatus.FAILED
                    return@launch
                }

                var anySuccess = false
                for ((npub, pubkey) in accounts) {
                    val prefs = config.pushPrefsFor(npub)
                    val body = json.encodeToString(
                        RegistrationPayload(
                            deviceToken = token,
                            pubkey = pubkey,
                            platform = "android",
                            mentions = prefs.mentions,
                            replies = prefs.replies,
                            dms = prefs.dms,
                            zaps = prefs.zaps,
                            // Zaps Only mode hard-disables reaction pushes regardless of the stored preference.
                            reactions = if (config.zapsOnlyMode) false else prefs.reactions,
                            reposts = prefs.reposts,
                        )
                    )
                    val request = Request.Builder()
                        .url("$serverUrl/register")
                        .post(body.toRequestBody("application/json".toMediaType()))
                        .build()
                    try {
                        if (httpClient.newCall(request).execute().isSuccessful) anySuccess = true
                    } catch (e: Exception) {
                        Log.w(TAG, "Push registration error for ${pubkey.take(8)}: ${e.message}")
                    }
                }

                _registrationStatus.value =
                    if (anySuccess) RegistrationStatus.REGISTERED else RegistrationStatus.FAILED
            } catch (e: Exception) {
                _registrationStatus.value = RegistrationStatus.FAILED
                Log.e(TAG, "Push registration error", e)
            }
        }
    }

    /**
     * Unregister from the push server.
     */
    fun unregister() {
        val config = configStore.config.value
        val token = _deviceToken.value
        val serverUrl = config.pushServerURL.trim()

        if (token.isNullOrEmpty() || serverUrl.isEmpty()) {
            _registrationStatus.value = RegistrationStatus.UNREGISTERED
            return
        }

        scope.launch {
            try {
                val pubkey = configStore.activeAccountHexPubkey.value
                val body = json.encodeToString(
                    UnregisterPayload(deviceToken = token, pubkey = pubkey)
                )

                val request = Request.Builder()
                    .url("$serverUrl/unregister")
                    .post(body.toRequestBody("application/json".toMediaType()))
                    .build()

                httpClient.newCall(request).execute()
                _registrationStatus.value = RegistrationStatus.UNREGISTERED
                Log.i(TAG, "Push unregistration sent")
            } catch (e: Exception) {
                Log.e(TAG, "Push unregistration error", e)
            }
        }
    }

    enum class RegistrationStatus {
        UNREGISTERED, REGISTERING, REGISTERED, FAILED
    }

    @kotlinx.serialization.Serializable
    private data class RegistrationPayload(
        val deviceToken: String,
        val pubkey: String,
        val platform: String,
        val mentions: Boolean,
        val replies: Boolean,
        val dms: Boolean,
        val zaps: Boolean,
        val reactions: Boolean,
        val reposts: Boolean,
    )

    @kotlinx.serialization.Serializable
    private data class UnregisterPayload(
        val deviceToken: String,
        val pubkey: String,
    )
}
