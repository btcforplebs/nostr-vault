package com.nostrvault.service

import com.nostrvault.data.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*

    fun FeedService.disconnect() {
        teardownAllFeedClients()
        _connectionStatus.value = "Disconnected"
        _connectionColor.value = "gray"
    }
