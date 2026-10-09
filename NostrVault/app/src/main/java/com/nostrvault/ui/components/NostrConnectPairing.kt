package com.nostrvault.ui.components

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeEncoder
import com.nostrvault.service.NIP46Service
import com.nostrvault.ui.theme.ErrorRed
import com.nostrvault.ui.theme.SecondaryText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Pairs a signer app through a nostrconnect:// request this app generates
 * (iOS "Sign in with Clave", SignInWithClaveView.swift). The request opens in
 * whatever signer on this phone takes nostrconnect: links (Amber and others),
 * and is shown as a QR code and a copyable link for a signer on another
 * device. The app then waits on the relays for the signer's answer carrying
 * our secret and hands the signer's pubkey to [onPaired], which stores and
 * connects it like a pasted bunker link.
 *
 * @param onPaired Stores the pairing and connects; returns an error message
 *   to show, or null on success.
 */
@Composable
fun NostrConnectPairing(
    accent: Color,
    onPaired: suspend (NIP46Service.NostrConnectRequest, String) -> String?,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()

    var phase by remember { mutableStateOf(Phase.IDLE) }
    var request by remember { mutableStateOf<NIP46Service.NostrConnectRequest?>(null) }
    var waitJob by remember { mutableStateOf<Job?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }

    DisposableEffect(Unit) { onDispose { waitJob?.cancel() } }

    /** Re-sends the same request: a signer that already approved it answers again without asking. */
    fun openSigner(req: NIP46Service.NostrConnectRequest) {
        notice = try {
            context.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(req.uri)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            null
        } catch (e: ActivityNotFoundException) {
            "No signer app on this phone opens nostrconnect links. Scan the code with your signer instead."
        }
    }

    fun cancel() {
        waitJob?.cancel()
        waitJob = null
        request = null
        notice = null
        phase = Phase.IDLE
    }

    fun start() {
        error = null
        val req = NIP46Service.makeNostrConnectRequest()
        if (req == null) {
            error = "Couldn't create a sign-in request. Try again."
            return
        }
        request = req
        phase = Phase.WAITING
        openSigner(req)
        waitJob?.cancel()
        waitJob = scope.launch {
            try {
                val signerPubkey = NIP46Service.awaitNostrConnect(req)
                if (signerPubkey == null) {
                    error = "The signer didn't answer. Tap to try again."
                } else {
                    phase = Phase.CONNECTING
                    error = onPaired(req, signerPubkey)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = e.message ?: "Pairing failed"
            }
            // Cancel resets its own state; this is the answered / timed-out end.
            request = null
            notice = null
            phase = Phase.IDLE
        }
    }

    Column(modifier = modifier.fillMaxWidth()) {
        when (phase) {
            Phase.IDLE -> {
                Button(
                    onClick = { start() },
                    colors = ButtonDefaults.buttonColors(containerColor = accent),
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Sign in with a signer app") }
                Text(
                    "Opens Amber or another signer on this phone, or shows a code to scan with a signer on another device.",
                    color = SecondaryText,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }

            Phase.WAITING -> {
                request?.let { req ->
                    NostrConnectQr(req.uri, Modifier.align(Alignment.CenterHorizontally))
                }
                Spacer(Modifier.height(8.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(color = accent, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Approve in your signer app, then come back here.", color = SecondaryText, fontSize = 12.sp)
                }
                notice?.let {
                    Text(it, color = SecondaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
                }
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.fillMaxWidth()) {
                    TextButton(onClick = { request?.let { openSigner(it) } }) { Text("Open signer again", color = accent) }
                    TextButton(onClick = { request?.let { clipboard.setText(AnnotatedString(it.uri)) } }) {
                        Text("Copy link", color = accent)
                    }
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = { cancel() }) { Text("Cancel", color = SecondaryText) }
                }
            }

            Phase.CONNECTING -> {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(color = accent, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Connecting to your signer…", color = SecondaryText, fontSize = 12.sp)
                }
            }
        }

        error?.let {
            Text(it, color = ErrorRed, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
        }
    }
}

private enum class Phase { IDLE, WAITING, CONNECTING }

@Composable
private fun NostrConnectQr(content: String, modifier: Modifier = Modifier) {
    val bitmap = remember(content) {
        runCatching { BarcodeEncoder().encodeBitmap(content, BarcodeFormat.QR_CODE, 480, 480) }.getOrNull()
    }
    if (bitmap != null) {
        // White quiet zone so the code scans on the dark theme.
        Box(
            modifier = modifier
                .clip(RoundedCornerShape(8.dp))
                .background(Color.White)
                .padding(8.dp),
        ) {
            Image(bitmap = bitmap.asImageBitmap(), contentDescription = "Sign-in QR code", modifier = Modifier.size(200.dp))
        }
    }
}
