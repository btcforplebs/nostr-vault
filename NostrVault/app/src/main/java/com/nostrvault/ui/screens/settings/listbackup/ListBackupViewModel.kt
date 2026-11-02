package com.nostrvault.ui.screens.settings.listbackup

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.ListBackupService
import com.nostrvault.service.ListHistory
import com.nostrvault.service.ListVersion
import com.nostrvault.service.ListVersionMerge
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

/** List backups and the wipe banner (iOS reads ListBackupService.shared directly). */
@HiltViewModel
class ListBackupViewModel @Inject constructor(
    private val service: ListBackupService,
    configStore: ConfigStore,
) : ViewModel() {
    val state: StateFlow<ListBackupService.State> = service.state
    val groups: StateFlow<Map<ListHistory.Key, List<ListVersion>>> = service.groups

    /** Wipes not yet dismissed, newest first. */
    val wipes: StateFlow<List<Pair<ListHistory.Key, ListHistory.Wipe>>> =
        combine(service.groups, service.dismissed) { g, d -> service.wipes(g, d) }
            .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    /** Changes with the active account, so pages reload for it. */
    val account: StateFlow<String> = configStore.activeAccountHexPubkey

    fun load() { viewModelScope.launch { service.load() } }

    fun dismiss(wipe: ListHistory.Wipe) = service.dismiss(wipe)

    suspend fun preview(old: ListVersion) = service.preview(old)

    suspend fun restore(old: ListVersion, shown: ListBackupService.Preview): String? = service.restore(old, shown)

    val profiles get() = service.profiles

    suspend fun mergeStart(key: ListHistory.Key) = service.mergeStart(key)

    fun opener(pubkey: String) = service.opener(pubkey)

    suspend fun saveMerge(key: ListHistory.Key, current: ListVersionMerge.Opened?, authors: Set<String>, rows: List<ListVersionMerge.Row>) =
        service.saveMerge(key, current, authors, rows)
}
