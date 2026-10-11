package com.nostrvault.service

import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*

    // ══════════════════════════════════════════════════════════════════
    // Search
    // ══════════════════════════════════════════════════════════════════

    fun FeedService.performSearch(query: String) {
        _isSearching.value = true
        _isSearchActive.value = true

        nostrService.globalSearch(query) { results ->
            val feedNotes = results.notes
            _searchResults.value = feedNotes
            _isSearching.value = false
        }
    }

    fun FeedService.clearSearch() {
        _isSearchActive.value = false
        _searchQuery.value = ""
        _searchResults.value = emptyList()
        _isSearching.value = false
        nostrService.cancelGlobalSearch()
    }
