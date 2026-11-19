package com.nostrvault.service

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Runs a chat's send on this service's app-lifetime scope (B5,
 * NV_MESSAGES_UX_CHECK 2026-11-18). A photo or video is compressed and
 * uploaded before it goes; that ran in the chat's own scope, so leaving the
 * chat mid-way cancelled it and the photo was lost without a word.
 */
fun DMService.launchDetached(block: suspend CoroutineScope.() -> Unit): Job = scope.launch(block = block)
