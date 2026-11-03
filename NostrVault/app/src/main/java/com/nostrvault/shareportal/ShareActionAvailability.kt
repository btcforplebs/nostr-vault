package com.nostrvault.shareportal

/**
 * Which actions the share sheet offers today. Mirrors
 * NVShareActionAvailability.swift. The classifier ranks all 13; only these are
 * shown, so a build never offers an action whose review card is a stub.
 *
 * Phase 2 lanes add their own action to [ready] when its handler, form and
 * review are done — one line each, nothing else in this file.
 */
object ShareActionAvailability {
    val ready: Set<ShareAction> = setOf(
        ShareAction.HIGHLIGHT,
        ShareAction.UPLOAD,
        // Lane A (phase 2).
        ShareAction.ARTICLE_CLIP,
        ShareAction.RECIPE,
        ShareAction.CALENDAR,
        ShareAction.STATUS,
        ShareAction.LABEL,
        // Lane D (phase 2).
        ShareAction.PAY,
        ShareAction.DM,
    )

    fun isReady(action: ShareAction): Boolean = action in ready

    /** [ranked] (from [ShareClassifier.classify]) with unready actions left out. */
    fun available(ranked: List<ShareAction>): List<ShareAction> = ranked.filter(::isReady)
}
