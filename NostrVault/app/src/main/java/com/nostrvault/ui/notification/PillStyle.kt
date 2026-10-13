package com.nostrvault.ui.notification

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.SuccessGreen
import com.nostrvault.ui.theme.ZapOrange

/** What a pill's colour says. One meaning each; see `docs/pills.md`. */
enum class PillTone {
    /** Level-1 errors only. */
    ERROR,
    /** Level-1 warnings only. */
    WARNING,
    /** A result that went through. */
    SUCCESS,
    /** In progress, on, and the app's own pills. */
    ACCENT,
    /** Off, hidden, undone, pending. */
    NEUTRAL,
}

/** The capsule colour for [tone]; accent is the theme's primary. */
@Composable
fun PillTone.color(): Color = when (this) {
    PillTone.ERROR -> ErrorRed.copy(alpha = 0.85f)
    PillTone.WARNING -> ZapOrange.copy(alpha = 0.85f)
    PillTone.SUCCESS -> SuccessGreen
    PillTone.ACCENT -> LocalNostrVaultColors.current.primary
    PillTone.NEUTRAL -> PillNeutral
}

private val PillNeutral = Color(0xFF595959)

/**
 * Regular: anything you can tap, and every error and result pill.
 * Small: information only.
 */
enum class PillSize(
    val font: TextUnit,
    val weight: FontWeight,
    val icon: Dp,
    val vertical: Dp,
    val horizontal: Dp,
) {
    REGULAR(13.sp, FontWeight.Bold, 12.dp, 10.dp, 20.dp),
    SMALL(12.sp, FontWeight.SemiBold, 11.dp, 6.dp, 14.dp),
}

object PillStyle {
    /** Between pills in the lane, and above the first. */
    val gap = 6.dp
    /** The lane never runs closer than this to the screen's sides. */
    val sideMargin = 16.dp
    /** The lane's top edge below the status bar: under the 8 + 48 + 8 dp top-bar row (iOS parity: #113). */
    val laneTop = 64.dp
    val shape = RoundedCornerShape(50)
    /** The spacing between an icon and its text inside a pill. */
    val innerGap = 6.dp
    /** Text inside every pill. */
    val textColor = Color.White
}

/**
 * The lane's capsule: solid [tone], the shared shadow and the padding for
 * [size]. Pass [vertical] to override the padding when a 44 dp button inside
 * sets the height; [onClick] makes the whole capsule the tap target. Put the
 * content's text and icon in [PillStyle.textColor]. iOS `.pillCapsule`.
 */
@Composable
fun Modifier.pillCapsule(
    tone: PillTone,
    size: PillSize = PillSize.REGULAR,
    vertical: Dp? = null,
    onClick: (() -> Unit)? = null,
): Modifier = pillCapsule(tone.color(), size, vertical, onClick)

/** [pillCapsule] with the colour already resolved, for a modifier chain built outside composition. */
fun Modifier.pillCapsule(
    color: Color,
    size: PillSize = PillSize.REGULAR,
    vertical: Dp? = null,
    onClick: (() -> Unit)? = null,
): Modifier = this
    .shadow(
        elevation = 8.dp,
        shape = PillStyle.shape,
        ambientColor = Color.Black.copy(alpha = 0.4f),
        spotColor = Color.Black.copy(alpha = 0.4f),
    )
    .background(color, PillStyle.shape)
    .clip(PillStyle.shape)
    .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
    .padding(vertical = vertical ?: size.vertical, horizontal = size.horizontal)

/** A pill's icon, sized for [size]. */
@Composable
fun PillIcon(icon: ImageVector, size: PillSize = PillSize.REGULAR, modifier: Modifier = Modifier) {
    Icon(imageVector = icon, contentDescription = null, tint = PillStyle.textColor, modifier = modifier.size(size.icon))
}

/** A pill's text, in the weight and size for [size]. */
@Composable
fun PillText(text: String, size: PillSize = PillSize.REGULAR, maxLines: Int = 1, modifier: Modifier = Modifier) {
    Text(
        text = text,
        color = PillStyle.textColor,
        fontSize = size.font,
        fontWeight = size.weight,
        maxLines = maxLines,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier,
    )
}

/**
 * The text button inside a regular pill (Undo, Edit): 13 sp bold, underlined,
 * at least 44 dp tall to tap. iOS `PillButton`.
 */
@Composable
fun PillButton(title: String, onClick: () -> Unit) {
    TextButton(
        onClick = onClick,
        contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp),
        modifier = Modifier.heightIn(min = 44.dp),
    ) {
        Text(
            text = title,
            color = PillStyle.textColor,
            fontSize = 13.sp,
            fontWeight = FontWeight.Bold,
            textDecoration = TextDecoration.Underline,
        )
    }
}
