package com.nostrvault.ui.navigation

import androidx.compose.runtime.staticCompositionLocalOf

/**
 * Opens a message thread with a pubkey, with a draft typed in. Provided
 * around the nav host, so a listing quoted deep inside a note can offer
 * Message seller without every screen threading a callback through (iOS
 * presents the thread from the listing sheet). Null (previews, anything
 * outside the nav host) hides Message seller there.
 */
val LocalMessageUser = staticCompositionLocalOf<((pubkey: String, draft: String) -> Unit)?> { null }
