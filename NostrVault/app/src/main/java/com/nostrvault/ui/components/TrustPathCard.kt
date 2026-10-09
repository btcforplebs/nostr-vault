package com.nostrvault.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.TrustPath
import com.nostrvault.data.model.TrustPathText
import com.nostrvault.service.NostrService
import com.nostrvault.service.TrustPathService
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.WindowBackground
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent

/**
 * The Trust Path singletons, reached from the card and the globe themselves so
 * every place that opens them (Event Info, the post bar) passes only the author.
 */
@EntryPoint
@InstallIn(SingletonComponent::class)
interface TrustPathEntryPoint {
    fun trustPathService(): TrustPathService
    fun nostrService(): NostrService
    /** The WOT tab's trust card follows and blocks with it. */
    fun feedService(): com.nostrvault.service.FeedService
}

@Composable
internal fun rememberTrustPathServices(): TrustPathEntryPoint {
    val context = LocalContext.current
    return remember(context) {
        EntryPointAccessors.fromApplication(context.applicationContext, TrustPathEntryPoint::class.java)
    }
}

/**
 * Event Info's Trust Path card: you on the left, the author on the right, and
 * the people you follow who follow them in between. Fixed layout and a single
 * line-draw animation, so nothing keeps redrawing while it's open. Tapping it
 * opens the Web of Trust globe ([TrustWebDialog]).
 *
 * Port of iOS Views/TrustPathCard.swift.
 */
@Composable
fun TrustPathCard(
    author: String,
    onProfileClick: ((String) -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val services = rememberTrustPathServices()
    val trust = services.trustPathService()
    val nostrService = services.nostrService()
    val profiles by nostrService.profiles.collectAsState()
    val me = trust.me

    var path by remember(author) { mutableStateOf<TrustPath?>(null) }
    var showingGlobe by remember { mutableStateOf(false) }

    LaunchedEffect(author) {
        val found = trust.path(author)
        nostrService.fetchMissingProfiles(listOf(me, author) + found.bridges)
        path = found
    }

    fun name(pubkey: String) = profiles[pubkey]?.bestName ?: "npub…${pubkey.takeLast(6)}"

    @Composable
    fun avatar(pubkey: String, size: Dp) {
        val profile = profiles[pubkey]
        AvatarImage(
            url = profile?.pictureURL,
            pubkey = pubkey,
            size = size,
            displayName = profile?.bestName,
            modifier = Modifier.border(2.dp, CardFill, CircleShape),
        )
    }

    val label = TrustPathText.label(path, ::name)
    val opens = path?.let { it.reach != TrustPath.Reach.YOU } == true
    val accent = LocalNostrVaultColors.current.primary

    Column(
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(CardFill)
            .then(if (opens) Modifier.clickable(role = Role.Button) { showingGlobe = true } else Modifier)
            .padding(14.dp)
            .clearAndSetSemantics {
                contentDescription = "Trust path. $label"
                if (opens) onClick(label = "Show your web of trust") { showingGlobe = true; true }
            },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            avatar(me, 32.dp)
            val current = path
            when {
                current == null -> {
                    // Same shape as the answer, so nothing jumps when it lands.
                    TrustPathLine(lit = false, broken = false, accent = accent, animated = false,
                        modifier = Modifier.weight(1f).alpha(0.5f))
                    avatar(author, 32.dp)
                }
                current.reach == TrustPath.Reach.YOU -> Spacer(Modifier.weight(1f))
                else -> {
                    val lit = current.reach != TrustPath.Reach.OUTSIDE && current.reach != TrustPath.Reach.UNKNOWN
                    TrustPathLine(lit = lit, broken = current.reach == TrustPath.Reach.OUTSIDE, accent = accent,
                        modifier = Modifier.weight(1f))
                    if (current.bridges.isNotEmpty()) {
                        Row(horizontalArrangement = Arrangement.spacedBy((-10).dp)) {
                            current.bridges.forEach { avatar(it, 26.dp) }
                        }
                        TrustPathLine(lit = true, broken = false, accent = accent, modifier = Modifier.weight(1f))
                    }
                    avatar(author, 32.dp)
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(label, color = SecondaryText, fontSize = 12.sp, modifier = Modifier.weight(1f))
            if (opens) {
                Icon(NostrVaultIcons.Navigate, contentDescription = null,
                    tint = SecondaryText.copy(alpha = 0.6f), modifier = Modifier.size(14.dp))
            }
        }
    }

    val shown = path
    if (showingGlobe && shown != null) {
        TrustWebDialog(
            author = author,
            initialPath = shown,
            onProfileClick = onProfileClick,
            onDismiss = { showingGlobe = false },
        )
    }
}

/** Matches the other cards in Event Info. */
private val CardFill = WindowBackground.copy(alpha = 0.5f)

/**
 * A line between two stops on the card. Draws itself once when it appears,
 * then stays still. Dashed and cut short when the author is outside your web.
 */
@Composable
private fun TrustPathLine(
    lit: Boolean,
    broken: Boolean,
    accent: Color,
    modifier: Modifier = Modifier,
    animated: Boolean = true,
) {
    val progress = remember { Animatable(if (animated && !Motion.isReduced) 0f else 1f) }
    LaunchedEffect(Unit) { progress.animateTo(1f, tween(600)) }
    Canvas(modifier.widthIn(min = 16.dp).height(32.dp)) {
        val y = size.height / 2
        val start = 4.dp.toPx()
        val end = size.width * (if (broken) 0.55f else 1f) - 4.dp.toPx()
        if (end <= start) return@Canvas
        val to = Offset(start + (end - start) * progress.value, y)
        val dash = if (broken) PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 4.dp.toPx())) else null
        if (lit) {
            // A soft glow under the line, like the iOS shadow.
            drawLine(accent.copy(alpha = 0.25f), Offset(start, y), to, strokeWidth = 6.dp.toPx(), cap = StrokeCap.Round)
        }
        drawLine(
            color = if (lit) accent else SecondaryText.copy(alpha = 0.5f),
            start = Offset(start, y),
            end = to,
            strokeWidth = if (lit) 2.dp.toPx() else 1.5.dp.toPx(),
            cap = StrokeCap.Round,
            pathEffect = dash,
        )
    }
}
