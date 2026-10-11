package com.nostrvault.ui.screens

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import kotlin.math.cos
import kotlin.math.sin

// ══════════════════════════════════════════════════════════════════
// Lesson pictures
// ══════════════════════════════════════════════════════════════════

/** The small diagram under each lesson (the mockup's pictures, drawn with
 *  Material icons). Decorative: the text says the same thing. */
@Composable
internal fun ImportTourArt(lesson: Int, modifier: Modifier = Modifier) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .height(110.dp)
            .clearAndSetSemantics {},
    ) {
        when (lesson) {
            0 -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    ArtSymbol(Icons.Default.Storage, SecondaryText, 22.dp, "relay")
                    Box(contentAlignment = Alignment.Center) {
                        ArtSymbol(Icons.Default.Storage, Muted, 22.dp, "deleted", Muted)
                        Icon(Icons.Default.Close, null, tint = ErrorRed, modifier = Modifier.size(16.dp).offset(y = (-7).dp))
                    }
                }
                Icon(Icons.AutoMirrored.Filled.ArrowForward, null, tint = WizardAccent, modifier = Modifier.size(20.dp))
                ArtSymbol(Icons.Default.PhoneAndroid, WizardAccent, 44.dp, "your copy", PrimaryText)
            }
            1 -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                ArtSymbol(Icons.Default.Language, Muted, 22.dp, "network", Muted)
                Icon(Icons.Default.Block, null, tint = ErrorRed, modifier = Modifier.size(18.dp))
                ArtSymbol(Icons.Default.PhoneAndroid, WizardAccent, 44.dp, "your relay", PrimaryText)
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(Icons.Default.ArrowUpward, null, tint = WizardAccent, modifier = Modifier.size(16.dp))
                    Icon(Icons.AutoMirrored.Filled.ArrowForward, null, tint = WizardAccent, modifier = Modifier.size(16.dp))
                    Icon(Icons.Default.ArrowDownward, null, tint = WizardAccent, modifier = Modifier.size(16.dp))
                }
            }
            2 -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                ArtSymbol(Icons.Default.PhoneAndroid, WizardAccent, 44.dp, "yours", PrimaryText)
                Icon(Icons.AutoMirrored.Filled.ArrowForward, null, tint = WizardAccent, modifier = Modifier.size(20.dp))
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    repeat(3) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Storage, null, tint = SecondaryText, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("public", color = SecondaryText, fontSize = 10.sp, fontWeight = FontWeight.Medium)
                        }
                    }
                }
            }
            3 -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Icon(Icons.Default.PhoneAndroid, null, tint = SecondaryText, modifier = Modifier.size(34.dp))
                Icon(Icons.Default.SwapHoriz, null, tint = Muted, modifier = Modifier.size(16.dp))
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Icon(Icons.Default.Computer, null, tint = WizardAccent, modifier = Modifier.size(46.dp))
                    Text("relay.you.com", color = PrimaryText, fontSize = 10.sp, fontWeight = FontWeight.Medium)
                    Text("up 24/7", color = SecondaryText, fontSize = 10.sp, fontWeight = FontWeight.Medium)
                }
            }
            else -> WebOfTrustArt()
        }
    }
}

@Composable
private fun ArtSymbol(icon: ImageVector, tint: Color, size: Dp, caption: String, captionColor: Color = SecondaryText) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(size))
        Text(caption, color = captionColor, fontSize = 10.sp, fontWeight = FontWeight.Medium)
    }
}

/** You, your follows, and the people they follow. */
@Composable
private fun WebOfTrustArt() {
    val spokes = 6
    Box(Modifier.size(width = 120.dp, height = 100.dp)) {
        Canvas(Modifier.matchParentSize()) {
            val center = Offset(size.width / 2, size.height / 2)
            for (k in 0 until spokes) {
                val angle = k * Math.PI / 3
                val end = Offset(
                    center.x + (44.dp.toPx() * cos(angle)).toFloat(),
                    center.y + (38.dp.toPx() * sin(angle)).toFloat(),
                )
                drawLine(WizardAccent.copy(alpha = 0.5f), center, end, strokeWidth = 1.dp.toPx())
            }
        }
        for (k in 0 until spokes) {
            val angle = k * Math.PI / 3
            Icon(
                Icons.Default.AccountCircle, null, tint = SecondaryText,
                modifier = Modifier
                    .align(Alignment.Center)
                    .offset(x = (44 * cos(angle)).dp, y = (38 * sin(angle)).dp)
                    .size(20.dp),
            )
        }
        Icon(Icons.Default.AccountCircle, null, tint = WizardAccent, modifier = Modifier.align(Alignment.Center).size(30.dp))
    }
}
