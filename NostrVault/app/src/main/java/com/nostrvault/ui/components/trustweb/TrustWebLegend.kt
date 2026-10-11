package com.nostrvault.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.SecondaryText
import java.text.NumberFormat

@Composable
internal fun TrustWebLegend(
    frame: TrustFrame?,
    me: String,
    author: String,
    accent: Color,
    name: (String) -> String,
) {
    if (frame == null || !frame.listFound) return
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        LegendDot(RingColor)
        Text(
            "${NumberFormat.getIntegerInstance().format(frame.ring.size)} " +
                if (frame.center == me) "you follow" else "${name(frame.center)} follows",
            color = SecondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        Spacer(Modifier.weight(1f).widthIn(min = 8.dp))
        if (frame.bridges.isNotEmpty()) {
            LegendDot(GlobeAccent)
            Text("${countText(frame)} follow ${name(author)}", color = accent, fontSize = 12.sp, maxLines = 1,
                overflow = TextOverflow.Ellipsis)
        }
    }
}
