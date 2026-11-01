package com.nostrvault.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * "Switched to <name>": a gray bubble mid-screen with the account's picture,
 * shown for a moment when the app switches account on its own (a Vault line
 * for another account was opened). Hosted once by MainActivity over every
 * screen; it takes no touches. iOS: AccountSwitchFlash.swift.
 */
object AccountSwitchFlash {
    /** The account just switched to (hex) and a token per showing, so a repeat restarts the timer. */
    data class Shown(val hex: String, val token: Long)

    private val _shown = MutableStateFlow<Shown?>(null)
    val shown: StateFlow<Shown?> = _shown.asStateFlow()
    private var next = 0L

    /** How long the bubble stays fully on screen. */
    const val HOLD_MS = 1_100L

    @Synchronized
    fun show(hex: String) {
        _shown.value = Shown(hex.lowercase(), ++next)
    }

    /** Hides the bubble, unless a newer one took its place. */
    fun hide(token: Long) {
        _shown.update { if (it?.token == token) null else it }
    }
}

@Composable
fun AccountSwitchFlashLayer(profiles: StateFlow<Map<String, FeedProfile>>) {
    val shown by AccountSwitchFlash.shown.collectAsState()
    val names by profiles.collectAsState()
    // Kept through the fade-out, after `shown` has gone back to null.
    var last by remember { mutableStateOf<AccountSwitchFlash.Shown?>(null) }
    shown?.let { last = it }
    LaunchedEffect(shown?.token) {
        val token = shown?.token ?: return@LaunchedEffect
        delay(AccountSwitchFlash.HOLD_MS)
        AccountSwitchFlash.hide(token)
    }
    Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxSize()) {
        AnimatedVisibility(
            visible = shown != null,
            enter = fadeIn(tween(160)) + scaleIn(tween(200), initialScale = 0.85f),
            exit = fadeOut(tween(200)) + scaleOut(tween(200), targetScale = 0.9f),
        ) {
            last?.let { AccountSwitchBubble(it.hex, names[it.hex]) }
        }
    }
}

@Composable
fun AccountSwitchBubble(hex: String, profile: FeedProfile?) {
    val name = profile?.bestName ?: ("npub…" + hex.takeLast(6))
    val shape = RoundedCornerShape(22.dp)
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .widthIn(min = 200.dp, max = 280.dp)
            .shadow(18.dp, shape)
            .background(Color(0xF0383838), shape)
            .padding(horizontal = 28.dp, vertical = 22.dp)
            .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
    ) {
        AvatarImage(url = profile?.pictureURL, pubkey = hex, size = 72.dp, displayName = name)
        Text(
            "Switched to $name",
            color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center, maxLines = 2,
        )
    }
}
