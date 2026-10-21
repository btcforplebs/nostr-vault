package com.nostrvault.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.People
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.LiveStream
import com.nostrvault.ui.theme.*

/**
 * One live tile: thumbnail, a LIVE pill (ENDED when [isLive] is false) and the
 * viewer count when the host publishes one, then title and host. Drawn by the
 * Live grid and by streams embedded in notes; callers add the tap.
 * iOS: LiveStreamCardView.
 */
@Composable
fun LiveStreamCard(
    stream: LiveStream,
    hostName: String,
    isLive: Boolean,
    thumbnailHeight: Dp,
    modifier: Modifier = Modifier,
) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = SecondaryGroupedBg,
        border = BorderStroke(0.5.dp, SeparatorColor),
        modifier = modifier.fillMaxWidth(),
    ) {
        Column {
            Box {
                LiveStreamThumbnail(
                    urls = stream.previewImageUrls,
                    modifier = Modifier.fillMaxWidth().height(thumbnailHeight),
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(8.dp),
                ) {
                    if (isLive) LivePill() else EndedPill()
                    val participants = stream.participants
                    if (isLive && participants != null) {
                        Spacer(Modifier.width(6.dp))
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .clip(CircleShape)
                                .background(Color.Black.copy(alpha = 0.55f))
                                .padding(horizontal = 6.dp, vertical = 3.dp),
                        ) {
                            Icon(Icons.Default.People, null, tint = Color.White, modifier = Modifier.size(11.dp))
                            Spacer(Modifier.width(3.dp))
                            Text("$participants", color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }
            Column(modifier = Modifier.padding(10.dp)) {
                Text(
                    text = stream.title ?: "Untitled stream",
                    color = PrimaryText,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(4.dp))
                Text(text = hostName, color = SecondaryText, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun LivePill() {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.55f))
            .padding(horizontal = 7.dp, vertical = 3.dp),
    ) {
        Box(Modifier.size(6.dp).clip(CircleShape).background(Color.Red))
        Spacer(Modifier.width(4.dp))
        Text("LIVE", color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun EndedPill() {
    Text(
        text = "ENDED",
        color = Color.White.copy(alpha = 0.8f),
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold,
        modifier = Modifier
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.55f))
            .padding(horizontal = 7.dp, vertical = 3.dp),
    )
}
