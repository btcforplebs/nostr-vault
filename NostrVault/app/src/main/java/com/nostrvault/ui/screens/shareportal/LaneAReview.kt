package com.nostrvault.ui.screens.shareportal

import androidx.compose.runtime.Composable
import com.nostrvault.service.shareportal.ShareSigner
import com.nostrvault.shareportal.ShareAction
import com.nostrvault.shareportal.ShareIntent
import com.nostrvault.ui.screens.ModeComposerKind

/** What a lane A card's Save or Publish came to. */
sealed interface LaneAResult {
    data class Done(val message: String) : LaneAResult
    data class Failed(val message: String) : LaneAResult
}

internal fun ShareSigner.Outcome.result(done: String): LaneAResult = when (this) {
    ShareSigner.Outcome.Published -> LaneAResult.Done(done)
    ShareSigner.Outcome.WrongAccount -> LaneAResult.Failed("Switch to that account first")
    ShareSigner.Outcome.NotSigned -> LaneAResult.Failed("Not signed")
}

/** Picks the lane A card for [intent]. Twin: each action's `<Action>ReviewView.swift`. */
@Composable
internal fun LaneAReview(
    intent: ShareIntent,
    busy: Boolean,
    active: String,
    viewModel: SharePortalReviewViewModel,
    onOpenEditor: (kindRoute: String, draftId: String) -> Unit = { _, _ -> },
) {
    val r = viewModel.router
    val needsSwitch = intent.account != null && intent.account != active
    val dismiss = { viewModel.dismiss(intent) }
    when (intent.action) {
        ShareAction.ARTICLE_CLIP -> ArticleClipReviewContent(
            intent, r.articleClip, busy, needsSwitch, viewModel::switchAccount, dismiss,
        ) { title, body, open ->
            var saved: String? = null
            viewModel.runAction(intent, after = { if (open) saved?.let { onOpenEditor(ModeComposerKind.ARTICLE.route, it) } }) {
                saved = r.articleClip.save(intent, title, body)
                if (saved != null) LaneAResult.Done("Saved to your article drafts")
                else LaneAResult.Failed("That account isn't on this device")
            }
        }
        ShareAction.RECIPE -> RecipeReviewContent(
            intent, r.recipe, busy, needsSwitch, viewModel::switchAccount, dismiss,
        ) { recipe, open ->
            var saved: String? = null
            viewModel.runAction(intent, after = { if (open) saved?.let { onOpenEditor(ModeComposerKind.RECIPE.route, it) } }) {
                saved = r.recipe.save(intent, recipe)
                if (saved != null) LaneAResult.Done("Saved to your recipe drafts")
                else LaneAResult.Failed("That account isn't on this device")
            }
        }
        ShareAction.CALENDAR -> CalendarReviewContent(
            intent, r.calendar, busy, needsSwitch, viewModel::switchAccount, dismiss,
            icsFile = r.calendar.icsFileOf(intent)?.let { viewModel.claimedFile(intent, it) },
        ) { ev -> viewModel.runAction(intent) { r.calendar.publish(intent, ev).result("Event published") } }
        ShareAction.STATUS -> StatusReviewContent(intent, r.status, busy, needsSwitch, viewModel::switchAccount, dismiss) { text, expiry ->
            viewModel.runAction(intent) { r.status.publish(intent, text, expiry).result("Status set") }
        }
        ShareAction.LABEL -> LabelReviewContent(intent, r.label, busy, needsSwitch, viewModel::switchAccount, dismiss) { label, comment ->
            viewModel.runAction(intent) {
                r.label.publish(intent, label, comment)?.result("Label published") ?: LaneAResult.Failed("No link to label")
            }
        }
        else -> Unit
    }
}

/** Which actions [LaneAReview] draws. */
internal val LaneAReviewActions = setOf(
    ShareAction.ARTICLE_CLIP, ShareAction.RECIPE, ShareAction.CALENDAR, ShareAction.STATUS, ShareAction.LABEL,
)
