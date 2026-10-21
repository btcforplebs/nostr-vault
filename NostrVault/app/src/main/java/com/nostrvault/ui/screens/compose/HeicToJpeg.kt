package com.nostrvault.ui.screens

import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.os.Build
import android.util.Log
import java.io.File

/**
 * A picture the phone's gallery hands over as HEIC/HEIF becomes a JPEG before
 * it is uploaded, as on iOS (`ComposeView+Attachments.swift`): the readers of a
 * note expect JPEG, and most browsers and clients cannot show HEIC.
 */
internal fun isHeic(mimeType: String): Boolean = mimeType.lowercase().substringBefore(';').trim() in HEIC_TYPES

private val HEIC_TYPES = setOf("image/heic", "image/heif", "image/heic-sequence", "image/heif-sequence")

internal const val JPEG_MIME = "image/jpeg"

private const val HEIC_JPEG_QUALITY = 80

/**
 * Re-encodes [source] as JPEG into [target] (quality 80, as iOS). The decoder
 * applies the picture's rotation, so the JPEG is upright and needs no EXIF.
 * False when this device cannot decode it (Android 8.x, or a decoder failure); the caller then keeps the original
 * bytes, the same as iOS.
 */
internal fun convertHeicToJpeg(source: File, target: File): Boolean =
    // ImageDecoder, and the platform's HEIF decoding, arrive with API 28; minSdk is 26.
    Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && decodeHeicToJpeg(source, target)

@androidx.annotation.RequiresApi(28)
private fun decodeHeicToJpeg(source: File, target: File): Boolean = try {
    val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(source)) { decoder, _, _ ->
        // JPEG has no alpha and a software bitmap is what compress() needs.
        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
    }
    val written = target.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, HEIC_JPEG_QUALITY, it) }
    bitmap.recycle()
    written
} catch (e: Throwable) {
    Log.w("ComposeNote", "HEIC to JPEG failed, keeping the original: ${e.message}")
    false
}
