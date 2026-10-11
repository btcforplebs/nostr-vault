package com.nostrvault.service

import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*

    /**
     * Fetch your follow list again, for the WOT tab's refresh button. Returns
     * once the load has finished, found a list or not (it has its own
     * timeout). One already running is waited on rather than started twice.
     */
    suspend fun FeedService.refreshContactList() {
        if (_isLoadingContacts.value) {
            _isLoadingContacts.first { !it }
            return
        }
        loadContactList()
    }
