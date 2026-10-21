package com.nostrvault.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.launch

/**
 * "Upload Media": Photos, Videos, Files, Magic Paste and Cancel, as the
 * action sheet iOS's upload button opens (`confirmationDialog`).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MediaUploadSheet(
    onDismiss: () -> Unit,
    onPickPhotos: () -> Unit,
    onPickVideos: () -> Unit,
    onPickFiles: () -> Unit,
    onMagicPaste: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    // Close first, then act, so a picker opens over the gallery, not the sheet.
    fun choose(action: () -> Unit) {
        scope.launch { sheetState.hide() }.invokeOnCompletion {
            onDismiss()
            action()
        }
    }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Surface1,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(bottom = 8.dp),
        ) {
            Text(
                "Upload Media",
                color = SecondaryText,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(bottom = 8.dp),
            )
            HorizontalDivider(color = SeparatorColor)
            for ((label, action) in listOf(
                "Photos" to onPickPhotos,
                "Videos" to onPickVideos,
                "Files" to onPickFiles,
                "Magic Paste" to onMagicPaste,
            )) {
                UploadSheetRow(label, color = colors.primary) { choose(action) }
                HorizontalDivider(color = SeparatorColor)
            }
            Spacer(Modifier.height(8.dp))
            UploadSheetRow("Cancel", color = colors.primary, bold = true) { choose {} }
        }
    }
}

@Composable
private fun UploadSheetRow(label: String, color: androidx.compose.ui.graphics.Color, bold: Boolean = false, onClick: () -> Unit) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 16.dp),
    ) {
        Text(label, color = color, fontSize = 18.sp, fontWeight = if (bold) FontWeight.SemiBold else FontWeight.Normal)
    }
}
