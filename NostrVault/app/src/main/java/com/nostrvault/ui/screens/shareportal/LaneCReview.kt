package com.nostrvault.ui.screens.shareportal

import androidx.compose.runtime.Composable
import com.nostrvault.shareportal.ShareAction
import com.nostrvault.shareportal.ShareIntent

/** Picks the lane C card for [intent] (Profile follow/block, Save for later). Twin: each action's
 *  `<Action>ShareReviewView.swift`. */
@Composable
internal fun LaneCReview(intent: ShareIntent, active: String, viewModel: SharePortalReviewViewModel) {
    val needsSwitch = intent.account != null && intent.account != active
    val dismiss = { viewModel.dismiss(intent) }
    when (intent.action) {
        ShareAction.PROFILE -> ProfileShareReviewContent(intent, needsSwitch, viewModel::switchAccount, dismiss)
        ShareAction.BOOKMARK -> BookmarkShareReviewContent(intent, needsSwitch, viewModel::switchAccount, dismiss)
        else -> Unit
    }
}

/** Which actions [LaneCReview] draws. */
internal val LaneCReviewActions = setOf(ShareAction.PROFILE, ShareAction.BOOKMARK)
