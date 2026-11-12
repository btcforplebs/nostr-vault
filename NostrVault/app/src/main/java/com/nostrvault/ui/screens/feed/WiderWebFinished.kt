package com.nostrvault.ui.screens.feed

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.runningFold

/**
 * One Unit each time the Vault's wider_network job goes from running to not running. The relay starts that job
 * by itself once setup ends (import_jobs_autowider.go), so Underrated must reload when it finishes even though
 * no button here started it (iOS: UnderratedEmptyAction's onChange(of: building)).
 */
fun widerWebFinished(building: Flow<Boolean>): Flow<Unit> =
    building
        .distinctUntilChanged()
        .runningFold(false to false) { (_, was), now -> was to now }
        .filter { (was, now) -> was && !now }
        .map { }
