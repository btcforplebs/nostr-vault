package com.nostrvault.ui.components

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.service.FeedService
import com.nostrvault.service.ListBackupService
import com.nostrvault.service.ListVersion
import com.nostrvault.service.ListVersionSave
import com.nostrvault.service.NostrService
import com.nostrvault.service.NuclearUnfollow
import com.nostrvault.service.TrustPathService
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

/**
 * Nuclear unfollow's list and save ([NuclearUnfollow]): who would go, ticked by
 * default; one warning, two from 25 people; the vault's backup first, then one
 * new follow list; Undo puts the backup back.
 */
@HiltViewModel
class NuclearUnfollowViewModel @Inject constructor(
    private val trustPathService: TrustPathService,
    private val listBackupService: ListBackupService,
    private val feedService: FeedService,
    private val nostrService: NostrService,
) : ViewModel() {

    enum class Step { LOADING, PICK, WARN, WARN_AGAIN, SAVING, DONE }

    data class UiState(
        val target: String = "",
        val step: Step = Step.LOADING,
        val people: List<String> = emptyList(),
        val checked: Set<String> = emptySet(),
        /** False when a relay stopped answering part way: the list may miss a few. */
        val complete: Boolean = true,
        val backedUp: Boolean = false,
        /** The list as it was, kept by the vault: what Undo puts back. */
        val before: ListVersion? = null,
        val unfollowed: Int = 0,
        val error: String? = null,
        val undoing: Boolean = false,
        val undone: Boolean = false,
    ) {
        val count get() = checked.size
    }

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    fun load(target: String) {
        if (_state.value.target == target && _state.value.step != Step.LOADING) return
        _state.value = UiState(target = target)
        viewModelScope.launch {
            val found = trustPathService.allBridges(target)
            val people = NuclearUnfollow.people(
                target, found?.bridges.orEmpty(), feedService.followedPubkeys.value.toSet(), trustPathService.me,
            )
            if (people.isNotEmpty()) nostrService.fetchMissingProfiles(people)
            _state.value = UiState(
                target = target,
                step = Step.PICK,
                people = people,
                checked = people.toSet(),
                complete = found?.complete ?: false,
                error = if (found == null) "No relay answered, so your follows who follow them couldn't be checked. Try again in a moment." else null,
            )
        }
    }

    fun toggle(pubkey: String) = _state.update {
        if (it.step != Step.PICK) it
        else it.copy(checked = if (pubkey in it.checked) it.checked - pubkey else it.checked + pubkey)
    }

    /** Unfollow N people → the warning(s) → the save. */
    fun next() {
        val s = _state.value
        when (s.step) {
            Step.PICK -> if (s.count > 0) _state.update { it.copy(step = Step.WARN, error = null) }
            Step.WARN -> if (NuclearUnfollow.warnings(s.count) == 2) _state.update { it.copy(step = Step.WARN_AGAIN) } else save()
            Step.WARN_AGAIN -> save()
            else -> Unit
        }
    }

    fun cancelWarning() = _state.update { if (it.step == Step.WARN || it.step == Step.WARN_AGAIN) it.copy(step = Step.PICK) else it }

    private fun save() {
        val remove = _state.value.checked
        _state.update { it.copy(step = Step.SAVING, backedUp = false, error = null) }
        // A follow list half-saved by leaving the screen is worse than one more second here.
        viewModelScope.launch {
            val outcome = withContext(NonCancellable) {
                listBackupService.unfollowMany(remove) { before -> _state.update { it.copy(backedUp = true, before = before) } }
            }
            _state.update {
                when (outcome) {
                    is ListVersionSave.Outcome.Saved -> it.copy(step = Step.DONE, unfollowed = remove.size)
                    is ListVersionSave.Outcome.Refused -> it.copy(step = Step.PICK, error = outcome.message)
                }
            }
        }
    }

    fun undo() {
        val before = _state.value.before ?: return
        if (_state.value.undoing || _state.value.undone) return
        _state.update { it.copy(undoing = true, error = null) }
        viewModelScope.launch {
            val error = withContext(NonCancellable) { listBackupService.undoUnfollow(before) }
            _state.update { it.copy(undoing = false, undone = error == null, error = error) }
        }
    }
}
