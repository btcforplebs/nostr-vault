package com.nostrvault.ui.components

import androidx.compose.runtime.compositionLocalOf

/**
 * Whether posts show a zap button: Appearance → Post buttons holds ⚡️
 * ([com.nostrvault.relay.HavenConfig.postButtonsShowZap]). Provided once in
 * MainActivity. Read by the action bar under a post (off, it still shows the
 * sats others sent, read-only), the live stream's Zap button and the article
 * reader's Zap pill, as on iOS. Profile zaps don't read it. Not static, so a
 * change redraws only the parts that read it.
 */
val LocalShowZapButton = compositionLocalOf { true }
