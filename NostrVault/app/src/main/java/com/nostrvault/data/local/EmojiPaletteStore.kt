package com.nostrvault.data.local

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

/** [EmojiPalette.State] saved on this phone. Never published. */
@Singleton
class EmojiPaletteStore @Inject constructor(@ApplicationContext context: Context) {
    private val prefs = context.getSharedPreferences("emoji_palette", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }

    private val _state = MutableStateFlow(load())
    val state: StateFlow<EmojiPalette.State> = _state.asStateFlow()

    @Synchronized
    fun recordUse(pick: ReactionPick) = save(EmojiPalette.recordUse(_state.value, pick))

    @Synchronized
    fun replaceSlot(replacing: ReactionPick, pick: ReactionPick) =
        save(EmojiPalette.replaceSlot(_state.value, replacing, pick))

    /** The custom emoji the account has used, by shortcode, for drawing its own reactions. */
    fun knownCustom(shortcode: String): ReactionPick? =
        (_state.value.recents + _state.value.slots).firstOrNull { it.shortcode == shortcode && it.url != null }

    private fun save(next: EmojiPalette.State) {
        _state.value = next
        prefs.edit().putString(KEY, json.encodeToString(EmojiPalette.State.serializer(), next)).apply()
    }

    private fun load(): EmojiPalette.State {
        val raw = prefs.getString(KEY, null) ?: return EmojiPalette.State()
        val saved = runCatching { json.decodeFromString(EmojiPalette.State.serializer(), raw) }.getOrNull()
            ?: return EmojiPalette.State()
        return EmojiPalette.normalized(saved)
    }

    private companion object {
        const val KEY = "state_v1"
    }
}
