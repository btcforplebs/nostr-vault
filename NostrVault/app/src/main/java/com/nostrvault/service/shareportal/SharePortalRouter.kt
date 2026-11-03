package com.nostrvault.service.shareportal

import com.nostrvault.service.shareportal.handlers.*
import com.nostrvault.shareportal.ShareAction
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Action → handler. Mirrors SharePortalRouter.swift. The only place that
 * lists every handler; the review screen asks here instead of switching on
 * the action itself.
 */
@Singleton
class SharePortalRouter @Inject constructor(
    val highlight: HighlightShareHandler,
) {
    fun handler(action: ShareAction): ShareHandler = when (action) {
        ShareAction.HIGHLIGHT -> highlight
        ShareAction.UPLOAD -> UploadShareHandler
        ShareAction.BOOKMARK -> BookmarkShareHandler
        ShareAction.PRIVATE_COPY -> PrivateCopyShareHandler
        ShareAction.ARTICLE_CLIP -> ArticleClipShareHandler
        ShareAction.MEDIA_POST -> MediaPostShareHandler
        ShareAction.RECIPE -> RecipeShareHandler
        ShareAction.PROFILE -> ProfileShareHandler
        ShareAction.PAY -> PayShareHandler
        ShareAction.DM -> DMShareHandler
        ShareAction.STATUS -> StatusShareHandler
        ShareAction.CALENDAR -> CalendarShareHandler
        ShareAction.LABEL -> LabelShareHandler
    }
}
