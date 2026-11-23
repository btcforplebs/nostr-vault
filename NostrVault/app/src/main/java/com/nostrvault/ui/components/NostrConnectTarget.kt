package com.nostrvault.ui.components

import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.MultiFormatWriter
import com.google.zxing.common.BitMatrix
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel

/**
 * Where the signer that answers a nostrconnect:// request is (iOS
 * SignInWithClaveView.Target). On this phone the request opens in the signer
 * app; on another device it is only shown as a QR code to scan, so a phone
 * with Amber installed doesn't jump away before the code is on screen.
 */
enum class NostrConnectTarget(
    val opensSigner: Boolean,
    val waitingText: String,
) {
    THIS_DEVICE(
        opensSigner = true,
        waitingText = "Approve in your signer app, then come back here.",
    ),
    OTHER_DEVICE(
        opensSigner = false,
        waitingText = "Scan this with the signer app on your other device, then approve there.",
    ),
}

/** The sign-in request as QR modules (no quiet zone: the card draws one). */
fun nostrConnectQrMatrix(content: String, size: Int = 480): BitMatrix? = runCatching {
    MultiFormatWriter().encode(
        content, BarcodeFormat.QR_CODE, size, size,
        mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 0),
    )
}.getOrNull()
