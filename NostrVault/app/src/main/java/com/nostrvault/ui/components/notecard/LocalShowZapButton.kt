package com.nostrvault.ui.components

import androidx.compose.runtime.staticCompositionLocalOf

/**
 * Whether posts show a zap button: Appearance → Post buttons holds ⚡️
 * ([com.nostrvault.relay.HavenConfig.postButtonsShowZap]). Provided once in
 * MainActivity. Off, a post still shows the sats others sent, read-only,
 * as iOS does. Profile zaps don't read it.
 */
val LocalShowZapButton = staticCompositionLocalOf { true }
