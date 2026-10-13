package com.nostrvault.ui.notification

import androidx.compose.runtime.staticCompositionLocalOf

/**
 * The app's [NotificationManager], for a composable without a view model that
 * has something to say in the lane (a copied link, a saved file). Provided
 * once in `MainActivity`; the fallback is an unhosted manager so a preview
 * does not crash, it just shows nothing.
 */
val LocalNotificationManager = staticCompositionLocalOf { NotificationManager() }
