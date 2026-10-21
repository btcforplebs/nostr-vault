package com.nostrvault.ui.screens

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.MediaStore
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch

@Composable
internal fun DivineVideoArea(clip: PickedClip?, busy: Boolean, onPicked: (Uri) -> Unit) {
    val context = LocalContext.current
    val colors = LocalNostrVaultColors.current
    val pickVideo = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri?.let(onPicked)
    }
    val record = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        result.data?.data?.let(onPicked)
    }
    fun launchCamera() {
        // The camera is optional in the manifest; some devices have no app
        // that records video.
        try {
            record.launch(
                Intent(MediaStore.ACTION_VIDEO_CAPTURE)
                    .putExtra(MediaStore.EXTRA_DURATION_LIMIT, ModeComposeViewModel.RECORD_LIMIT_SECONDS)
            )
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(context, "No camera app to record with", Toast.LENGTH_SHORT).show()
        }
    }
    // The manifest declares CAMERA (QR scanning), so the system camera intent
    // is refused until the permission is granted.
    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) launchCamera()
    }

    val limit = ModeComposeViewModel.RECORD_LIMIT_SECONDS
    // The one rule a diVine has, said before anything is picked.
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Text("A looping video, up to $limit seconds", color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(2.dp))
        Text(
            "Record one, or choose a video. Longer videos keep their first $limit seconds.",
            color = SecondaryText, fontSize = 13.sp, textAlign = TextAlign.Center,
        )
    }

    // The cap goes on before aspectRatio, which then sizes from that height;
    // after it, a full-width 9:16 box is already ~640dp and the cap is ignored.
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Box(
            modifier = Modifier
                .heightIn(max = 420.dp)
                .aspectRatio(9f / 16f, matchHeightConstraintsFirst = true)
                .clip(RoundedCornerShape(16.dp))
                .background(Color.Black),
            contentAlignment = Alignment.Center,
        ) {
            if (clip != null) {
                Image(
                    bitmap = clip.poster.asImageBitmap(),
                    contentDescription = "Chosen video",
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize(),
                )
            } else if (busy) {
                CircularProgressIndicator(color = Color.White)
            } else {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.semantics(mergeDescendants = true) {
                        contentDescription = "Up to $limit seconds"
                    },
                ) {
                    Text("${limit}s", color = Color.White, fontSize = 56.sp, fontWeight = FontWeight.Black)
                    Text("max length", color = Color.White.copy(alpha = 0.7f), fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }

    clip?.let { LengthMeter(it, limit) }

    fun record() {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            launchCamera()
        } else {
            cameraPermission.launch(Manifest.permission.CAMERA)
        }
    }
    fun choose() = pickVideo.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly))
    val outline = ButtonDefaults.outlinedButtonColors(contentColor = colors.primary)
    val border = BorderStroke(1.dp, colors.primary.copy(alpha = 0.6f))

    if (clip == null) {
        // Stacked and large while they are the next step.
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(
                onClick = ::record,
                enabled = !busy,
                colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                modifier = Modifier.fillMaxWidth().height(52.dp),
            ) {
                Icon(NostrVaultIcons.Video, contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text("Record a video", color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
            OutlinedButton(
                onClick = ::choose,
                enabled = !busy,
                colors = outline,
                border = border,
                modifier = Modifier.fillMaxWidth().height(52.dp),
            ) {
                Text("Choose from gallery", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    } else if (!busy) {
        // A compact row once there is a clip; Post is the next step.
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedButton(onClick = ::record, colors = outline, border = border, modifier = Modifier.weight(1f)) {
                Icon(NostrVaultIcons.Video, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("Record again", maxLines = 1)
            }
            OutlinedButton(onClick = ::choose, colors = outline, border = border, modifier = Modifier.weight(1f)) {
                Text("Choose another", maxLines = 1)
            }
        }
    }
}

/** How much of the limit the picked clip uses. */
@Composable
private fun LengthMeter(clip: PickedClip, limit: Int) {
    val colors = LocalNostrVaultColors.current
    val used = (clip.durationSeconds / limit).toFloat().coerceIn(0f, 1f)
    Column(
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.fillMaxWidth().semantics(mergeDescendants = true) {},
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(6.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(SecondaryText.copy(alpha = 0.25f)),
        ) {
            Box(
                Modifier
                    .fillMaxWidth(used)
                    .height(6.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(colors.primary),
            )
        }
        Row(Modifier.fillMaxWidth()) {
            Text(
                String.format(java.util.Locale.US, "%.1fs of %ds", clip.durationSeconds, limit),
                color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.weight(1f))
            Text(if (clip.wasTrimmed) "Trimmed to fit" else "Fits", color = SecondaryText, fontSize = 13.sp)
        }
    }
}
