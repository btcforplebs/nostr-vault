package com.nostrvault.data.local

import android.content.Context
import android.content.SharedPreferences
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Proof-of-work preferences for NIP-13 mining.
 * Backed by SharedPreferences for immediate persistence.
 * Port of PowPreferences.swift.
 */
@Singleton
class PowPreferences @Inject constructor(
    @ApplicationContext context: Context,
) {
    companion object {
        const val MIN_DIFFICULTY = 8
        const val MAX_DIFFICULTY = 32

        /** Slider stops between the ends, so it moves one bit at a time as the iOS stepper does. */
        const val SLIDER_STEPS = MAX_DIFFICULTY - MIN_DIFFICULTY - 1

        private const val PREFS_NAME = "pow_preferences"
        private const val KEY_NOTE_ENABLED = "pow_note_enabled"
        private const val KEY_NOTE_DIFFICULTY = "pow_note_difficulty"
        private const val KEY_REACTION_ENABLED = "pow_reaction_enabled"
        private const val KEY_REACTION_DIFFICULTY = "pow_reaction_difficulty"
        private const val KEY_DM_ENABLED = "pow_dm_enabled"
        private const val KEY_DM_DIFFICULTY = "pow_dm_difficulty"
    }

    data class Snapshot(
        val noteEnabled: Boolean,
        val noteDifficulty: Int,
        val reactionEnabled: Boolean,
        val reactionDifficulty: Int,
        val dmEnabled: Boolean,
        val dmDifficulty: Int,
    )

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private val _noteEnabled = MutableStateFlow(prefs.getBoolean(KEY_NOTE_ENABLED, true))
    val noteEnabled: StateFlow<Boolean> = _noteEnabled.asStateFlow()

    private val _noteDifficulty = MutableStateFlow(prefs.getInt(KEY_NOTE_DIFFICULTY, 16))
    val noteDifficulty: StateFlow<Int> = _noteDifficulty.asStateFlow()

    private val _reactionEnabled = MutableStateFlow(prefs.getBoolean(KEY_REACTION_ENABLED, true))
    val reactionEnabled: StateFlow<Boolean> = _reactionEnabled.asStateFlow()

    private val _reactionDifficulty = MutableStateFlow(prefs.getInt(KEY_REACTION_DIFFICULTY, 12))
    val reactionDifficulty: StateFlow<Int> = _reactionDifficulty.asStateFlow()

    private val _dmEnabled = MutableStateFlow(prefs.getBoolean(KEY_DM_ENABLED, true))
    val dmEnabled: StateFlow<Boolean> = _dmEnabled.asStateFlow()

    private val _dmDifficulty = MutableStateFlow(prefs.getInt(KEY_DM_DIFFICULTY, 12))
    val dmDifficulty: StateFlow<Int> = _dmDifficulty.asStateFlow()

    /** Thread-safe snapshot for background signing. */
    fun snapshot(): Snapshot = Snapshot(
        noteEnabled = prefs.getBoolean(KEY_NOTE_ENABLED, true),
        noteDifficulty = prefs.getInt(KEY_NOTE_DIFFICULTY, 16),
        reactionEnabled = prefs.getBoolean(KEY_REACTION_ENABLED, true),
        reactionDifficulty = prefs.getInt(KEY_REACTION_DIFFICULTY, 12),
        dmEnabled = prefs.getBoolean(KEY_DM_ENABLED, true),
        dmDifficulty = prefs.getInt(KEY_DM_DIFFICULTY, 12),
    )

    fun setNoteEnabled(enabled: Boolean) {
        _noteEnabled.value = enabled
        prefs.edit().putBoolean(KEY_NOTE_ENABLED, enabled).apply()
    }

    fun setNoteDifficulty(difficulty: Int) {
        val clamped = difficulty.coerceIn(MIN_DIFFICULTY, MAX_DIFFICULTY)
        _noteDifficulty.value = clamped
        prefs.edit().putInt(KEY_NOTE_DIFFICULTY, clamped).apply()
    }

    fun setReactionEnabled(enabled: Boolean) {
        _reactionEnabled.value = enabled
        prefs.edit().putBoolean(KEY_REACTION_ENABLED, enabled).apply()
    }

    fun setReactionDifficulty(difficulty: Int) {
        val clamped = difficulty.coerceIn(MIN_DIFFICULTY, MAX_DIFFICULTY)
        _reactionDifficulty.value = clamped
        prefs.edit().putInt(KEY_REACTION_DIFFICULTY, clamped).apply()
    }

    fun setDmEnabled(enabled: Boolean) {
        _dmEnabled.value = enabled
        prefs.edit().putBoolean(KEY_DM_ENABLED, enabled).apply()
    }

    fun setDmDifficulty(difficulty: Int) {
        val clamped = difficulty.coerceIn(MIN_DIFFICULTY, MAX_DIFFICULTY)
        _dmDifficulty.value = clamped
        prefs.edit().putInt(KEY_DM_DIFFICULTY, clamped).apply()
    }

    /** Resolve difficulty for a given event kind. Returns 0 if PoW is disabled for that kind. */
    fun difficultyForKind(kind: Int): Int {
        val snap = snapshot()
        return when (kind) {
            1, 6, 30023 -> if (snap.noteEnabled) snap.noteDifficulty else 0
            7 -> if (snap.reactionEnabled) snap.reactionDifficulty else 0
            4, 14 -> if (snap.dmEnabled) snap.dmDifficulty else 0
            else -> 0
        }
    }
}
