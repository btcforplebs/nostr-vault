package com.nostrvault.ui.screens

import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch

@Composable
internal fun CoverPicker(cover: Uri?, onPicked: (Uri?) -> Unit) {
    val context = LocalContext.current
    val colors = LocalNostrVaultColors.current
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) onPicked(uri)
    }
    val preview = remember(cover) {
        cover?.let { uri ->
            runCatching {
                context.contentResolver.openInputStream(uri)?.use { input ->
                    val opts = BitmapFactory.Options().apply { inSampleSize = 4 }
                    BitmapFactory.decodeStream(input, null, opts)
                }
            }.getOrNull()
        }
    }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(160.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.08f))
            .clickable { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
        contentAlignment = Alignment.Center,
    ) {
        if (preview != null) {
            Image(preview.asImageBitmap(), contentDescription = "Cover photo",
                contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        } else {
            Text("Add a cover photo", color = colors.primary)
        }
    }
}
