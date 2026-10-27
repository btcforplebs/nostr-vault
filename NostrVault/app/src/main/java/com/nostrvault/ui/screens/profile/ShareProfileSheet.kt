package com.nostrvault.ui.screens.profile

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
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeEncoder
import com.nostrvault.ui.navigation.ProfileWebLink
import com.nostrvault.ui.theme.*

/**
 * Share profile: a QR code of `https://nostrvault.app/p/<npub>`, Copy link
 * and the system share sheet. Opening or scanning the link in the app opens
 * this profile; anywhere else it opens the profile on the web.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ShareProfileSheet(
    npub: String,
    name: String?,
    onDismiss: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val link = remember(npub) { ProfileWebLink.forNpub(npub) }
    // A white quiet zone keeps the code scannable on the dark sheet.
    val qr = remember(link) { runCatching { BarcodeEncoder().encodeBitmap(link, BarcodeFormat.QR_CODE, 600, 600) }.getOrNull() }
    var copied by remember { mutableStateOf(false) }

    // Fully open: half-way hides Copy link and Share below the code.
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = Surface2) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 24.dp).padding(bottom = 24.dp),
        ) {
            Text("Share profile", color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            name?.takeIf { it.isNotBlank() }?.let {
                Text(it, color = SecondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 2.dp))
            }
            Spacer(Modifier.height(16.dp))
            if (qr != null) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.clip(RoundedCornerShape(16.dp)).background(Color.White).padding(12.dp),
                ) {
                    Image(qr.asImageBitmap(), contentDescription = "QR code for $link", modifier = Modifier.size(220.dp))
                }
            }
            Text(
                link,
                color = SecondaryText,
                fontSize = 12.sp,
                textAlign = TextAlign.Center,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 12.dp),
            )
            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                OutlinedButton(
                    onClick = { clipboard.setText(AnnotatedString(link)); copied = true },
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(NostrVaultIcons.Copy, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(if (copied) "Copied" else "Copy link")
                }
                Button(
                    onClick = {
                        val send = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(android.content.Intent.EXTRA_TEXT, link)
                        }
                        context.startActivity(android.content.Intent.createChooser(send, "Share profile"))
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(NostrVaultIcons.Share, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Share")
                }
            }
        }
    }
}
