package com.nostrvault.ui.screens.settings

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.AccentPalette
import com.nostrvault.ui.theme.Ink
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.Surface1
import com.nostrvault.ui.theme.TertiaryText
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/** Hue order of the wheel, clockwise from 3 o'clock (sweepGradient's start). */
private val HUES = listOf(
    Color.Red, Color.Yellow, Color.Green, Color.Cyan, Color.Blue, Color.Magenta, Color.Red,
)

/**
 * The "Custom colour" line under the ready-made row (twin of the SwiftUI
 * ColorPicker in AccentSettingsSection.swift). Picked when the accent is not a
 * preset; tapping it opens the wheel.
 */
@Composable
internal fun AccentCustomRow(picked: String, onPick: (String) -> Unit) {
    var open by rememberSaveable { mutableStateOf(false) }
    val custom = !AccentPalette.isPreset(picked)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 6.dp)
            .clip(CircleShape)
            .clickable(role = Role.Button) { open = true }
            .semantics {
                contentDescription = "Custom colour"
                selected = custom
                stateDescription = if (custom) "Picked, ${picked.uppercase()}" else "Opens the colour wheel"
            }
            .testTag("appearance.accentWheel")
            .padding(vertical = 4.dp),
    ) {
        // Rainbow ring, with the custom pick inside it once there is one.
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(40.dp)
                .border(2.dp, if (custom) Ink else Color.Transparent, CircleShape),
        ) {
            Canvas(Modifier.size(28.dp)) {
                drawCircle(Brush.sweepGradient(HUES))
                drawCircle(
                    if (custom) AccentPalette.swatch(picked) else Surface1,
                    radius = size.minDimension / 2 - 4.dp.toPx(),
                )
            }
        }
        Text("Custom colour", color = PrimaryText, fontSize = 15.sp, modifier = Modifier.weight(1f))
        if (custom) {
            Text(picked.uppercase(), color = SecondaryText, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
        }
    }
    if (open) {
        AccentWheelDialog(
            initialHex = picked,
            onDone = { hex -> open = false; onPick(AccentPalette.setting(hex)) },
            onDismiss = { open = false },
        )
    }
}

/**
 * Hue and depth on the wheel, brightness on the slider, or a typed #rrggbb.
 * The Dark and Light previews follow every move; nothing is saved until
 * "Use colour", so dragging does not rewrite config or redraw the app.
 */
@Composable
private fun AccentWheelDialog(initialHex: String, onDone: (String) -> Unit, onDismiss: () -> Unit) {
    val start = remember(initialHex) { toHsv(initialHex) }
    var hue by rememberSaveable { mutableFloatStateOf(start[0]) }
    var sat by rememberSaveable { mutableFloatStateOf(start[1]) }
    var value by rememberSaveable { mutableFloatStateOf(start[2]) }
    var typed by rememberSaveable { mutableStateOf(initialHex.uppercase()) }
    val hex = toHex(hue, sat, value)
    val accent = LocalNostrVaultColors.current.primary

    fun fromWheel(h: Float, s: Float) { hue = h; sat = s; typed = toHex(h, s, value).uppercase() }

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Surface1,
        title = { Text("Custom colour", color = PrimaryText) },
        text = {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.verticalScroll(rememberScrollState()),
            ) {
                HueWheel(hue, sat, value, ::fromWheel)
                Spacer(Modifier.height(12.dp))
                // Brightness: black to the full-strength colour, drawn under a bare slider.
                Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxWidth()) {
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 4.dp)
                            .height(10.dp)
                            .clip(CircleShape)
                            .background(Brush.horizontalGradient(listOf(Color.Black, AccentPalette.swatch(toHex(hue, sat, 1f))))),
                    )
                    Slider(
                        value = value,
                        onValueChange = { value = it; typed = toHex(hue, sat, it).uppercase() },
                        colors = SliderDefaults.colors(
                            thumbColor = Ink,
                            activeTrackColor = Color.Transparent,
                            inactiveTrackColor = Color.Transparent,
                            activeTickColor = Color.Transparent,
                            inactiveTickColor = Color.Transparent,
                        ),
                        modifier = Modifier
                            .fillMaxWidth()
                            .semantics { contentDescription = "Brightness" }
                            .testTag("appearance.accentWheel.brightness"),
                    )
                }
                OutlinedTextField(
                    value = typed,
                    onValueChange = { text ->
                        typed = text.take(7).uppercase()
                        AccentPalette.normalize(if (text.startsWith("#")) text else "#$text")?.let {
                            val hsv = toHsv(it)
                            hue = hsv[0]; sat = hsv[1]; value = hsv[2]
                        }
                    },
                    label = { Text("Hex") },
                    singleLine = true,
                    textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 15.sp),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = PrimaryText, unfocusedTextColor = PrimaryText,
                        cursorColor = accent, focusedBorderColor = accent, focusedLabelColor = accent,
                    ),
                    modifier = Modifier.fillMaxWidth().testTag("appearance.accentWheel.hex"),
                )
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                    AccentPreview(hex, light = false, Modifier.weight(1f))
                    AccentPreview(hex, light = true, Modifier.weight(1f))
                }
                Text(
                    if (AccentPalette.shiftsInLight(hex)) "Too pale to read on white, so Light mode uses a deeper shade for text."
                    else "Buttons, links and highlights use this colour.",
                    color = TertiaryText,
                    fontSize = 12.sp,
                    modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onDone(hex) }, modifier = Modifier.testTag("appearance.accentWheel.use")) {
                Text("Use colour", color = accent)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel", color = SecondaryText) }
        },
    )
}

/** Hue round the edge, depth (saturation) from the white centre out; dimmed by brightness. */
@Composable
private fun HueWheel(hue: Float, sat: Float, value: Float, onMove: (Float, Float) -> Unit) {
    val ring = Ink
    Canvas(
        Modifier
            .size(208.dp)
            .semantics {
                contentDescription = "Colour wheel"
                stateDescription = "Hue ${hue.roundToInt()} degrees, depth ${(sat * 100).roundToInt()} percent"
            }
            .testTag("appearance.accentWheel.wheel")
            .pointerInput(Unit) {
                fun pick(p: Offset) {
                    val r = min(size.width, size.height) / 2f
                    val dx = p.x - size.width / 2f
                    val dy = p.y - size.height / 2f
                    val deg = Math.toDegrees(atan2(dy, dx).toDouble()).toFloat()
                    onMove((deg + 360f) % 360f, (hypot(dx, dy) / r).coerceIn(0f, 1f))
                }
                awaitEachGesture {
                    val down = awaitFirstDown()
                    down.consume()
                    pick(down.position)
                    while (true) {
                        val event = awaitPointerEvent()
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        if (!change.pressed) break
                        change.consume()
                        pick(change.position)
                    }
                }
            },
    ) {
        val r = size.minDimension / 2
        drawCircle(Brush.sweepGradient(HUES))
        drawCircle(Brush.radialGradient(listOf(Color.White, Color.White.copy(alpha = 0f)), center, r))
        drawCircle(Color.Black.copy(alpha = 1f - value))
        drawCircle(ring.copy(alpha = 0.14f), style = Stroke(1.dp.toPx()))
        val rad = Math.toRadians(hue.toDouble())
        val at = Offset(center.x + (cos(rad) * sat * r).toFloat(), center.y + (sin(rad) * sat * r).toFloat())
        drawCircle(AccentPalette.swatch(toHex(hue, sat, value)), 11.dp.toPx(), at)
        drawCircle(Color.White, 11.dp.toPx(), at, style = Stroke(3.dp.toPx()))
        drawCircle(Color.Black.copy(alpha = 0.35f), 12.5.dp.toPx(), at, style = Stroke(1.dp.toPx()))
    }
}

private fun toHsv(hex: String): FloatArray {
    val out = FloatArray(3)
    android.graphics.Color.colorToHSV(android.graphics.Color.parseColor(AccentPalette.hex(hex)), out)
    return out
}

private fun toHex(h: Float, s: Float, v: Float): String =
    String.format(java.util.Locale.ROOT, "#%06x", android.graphics.Color.HSVToColor(floatArrayOf(h, s, v)) and 0xFFFFFF)
