package com.nostrvault.ui.components.sno

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.SnoObject
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.Motion
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.TertiaryText
import kotlin.math.PI

/** Faces above which a quote card shows the object's line and "Tap to view" instead of drawing it. */
private const val CARD_FACE_LIMIT = 4_000

/** One slow turn: a full revolution in this many seconds. */
private const val SPIN_SECONDS = 24f

private val PITCH_LIMIT = (85.0 * PI / 180.0).toFloat()

/** The read of a 33331 event, kept per event so a recomposition does not re-parse it. */
@Composable
internal fun rememberSnoRead(note: FeedNote): SnoObject.Read =
    remember(note.id) { SnoObject.read(note.content) }

/** NIP-31's line for a client that cannot draw the object. */
internal fun FeedNote.altText(): String? =
    tags.firstOrNull { it.size >= 2 && it[0] == "alt" }?.get(1)?.takeIf { it.isNotBlank() }

/**
 * The object, turning slowly. [interactive] lets a drag turn it (yaw, and pitch
 * held within ±85°) and a double tap put it back; the spin carries on from
 * wherever the finger left it. A quote card passes false, so its scroll stays
 * a scroll. Under Reduce Motion it does not spin.
 */
@Composable
internal fun SnoStage(obj: SnoObject, interactive: Boolean, modifier: Modifier = Modifier) {
    val scene = remember(obj) { SnoScene(obj) }
    var yaw by remember { mutableFloatStateOf(-0.6f) }
    var pitch by remember { mutableFloatStateOf(0.35f) }
    var dragging by remember { mutableStateOf(false) }
    val accent = LocalNostrVaultColors.current.primary
    val pointRadius = with(LocalDensity.current) { 2.dp.toPx() }

    LaunchedEffect(scene) {
        if (Motion.isReduced) return@LaunchedEffect
        var last = 0L
        // Runs only while the stage is on screen: a list disposes it when it scrolls away.
        while (true) {
            withFrameNanos { now ->
                if (last != 0L && !dragging) yaw += (now - last) / 1e9f * (2f * PI.toFloat() / SPIN_SECONDS)
                last = now
            }
        }
    }

    val label = "3D object, ${obj.name.ifBlank { "untitled" }}, ${obj.vertexCount} vertices"
    val turn = (PI / 6).toFloat()
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(Color(0xFF0B0B10))
            .semantics {
                contentDescription = label
                if (interactive) {
                    customActions = listOf(
                        CustomAccessibilityAction("Turn left") { yaw -= turn; true },
                        CustomAccessibilityAction("Turn right") { yaw += turn; true },
                    )
                }
            }
            .then(
                if (!interactive) Modifier else Modifier
                    .pointerInput(scene) {
                        detectDragGestures(
                            onDragStart = { dragging = true },
                            onDragEnd = { dragging = false },
                            onDragCancel = { dragging = false },
                        ) { change, drag ->
                            change.consume()
                            yaw += drag.x / size.width * PI.toFloat()
                            pitch = (pitch + drag.y / size.height * PI.toFloat()).coerceIn(-PITCH_LIMIT, PITCH_LIMIT)
                        }
                    }
                    .pointerInput(scene) {
                        detectTapGestures(onDoubleTap = { yaw = -0.6f; pitch = 0.35f })
                    },
            ),
    ) {
        Canvas(Modifier.fillMaxSize()) { drawSno(scene, yaw, pitch, accent, pointRadius) }
    }
}

/**
 * The body of a quoted 33331 event: a square stage turning slowly, the object's
 * name, a "3D object" chip and how many vertices. A payload §1.9 rejects shows
 * its `alt` and the reason instead, never the JSON (§4).
 */
@Composable
internal fun SnoQuoteBody(note: FeedNote) {
    when (val read = rememberSnoRead(note)) {
        is SnoObject.Read.Rejected -> SnoRejected(note.altText(), read.reason)
        is SnoObject.Read.Ok -> {
            val obj = read.obj
            if (obj.faceCount > CARD_FACE_LIMIT) {
                SnoCaption(obj, note.altText())
                Text("Tap to view", color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 2.dp))
            } else {
                SnoStage(obj, interactive = false, modifier = Modifier.fillMaxWidth().aspectRatio(1f))
                Spacer(Modifier.height(8.dp))
                SnoCaption(obj, null)
            }
        }
    }
}

/** The body of a 33331 event on its thread page: a large stage you can turn. */
@Composable
internal fun SnoHeroBody(note: FeedNote) {
    when (val read = rememberSnoRead(note)) {
        is SnoObject.Read.Rejected -> SnoRejected(note.altText(), read.reason)
        is SnoObject.Read.Ok -> Column {
            SnoStage(read.obj, interactive = true, modifier = Modifier.fillMaxWidth().aspectRatio(1f))
            Spacer(Modifier.height(10.dp))
            SnoCaption(read.obj, null, large = true)
            Text(
                "Drag to turn · double-tap to reset",
                color = TertiaryText,
                fontSize = 12.sp,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
    }
}

@Composable
private fun SnoCaption(obj: SnoObject, alt: String?, large: Boolean = false) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            obj.name.ifBlank { "Untitled object" },
            color = PrimaryText,
            fontWeight = FontWeight.SemiBold,
            fontSize = if (large) 17.sp else 13.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            "3D object",
            color = LocalNostrVaultColors.current.primary,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier
                .clip(RoundedCornerShape(6.dp))
                .background(LocalNostrVaultColors.current.primary.copy(alpha = 0.15f))
                .padding(horizontal = 6.dp, vertical = 2.dp),
        )
        Spacer(Modifier.width(8.dp))
        Text("${obj.vertexCount} vertices", color = SecondaryText, fontSize = 12.sp, maxLines = 1)
    }
    if (alt != null) Text(alt, color = SecondaryText, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
}

/** §4: an object that fails §1.9 is never drawn; say what it is (alt) and why it is not shown. */
@Composable
private fun SnoRejected(alt: String?, reason: String) {
    Column {
        Text(alt ?: "A 3D object", color = SecondaryText, fontSize = 13.sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
        Text("Can't show this 3D object: $reason", color = TertiaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 2.dp))
    }
}
