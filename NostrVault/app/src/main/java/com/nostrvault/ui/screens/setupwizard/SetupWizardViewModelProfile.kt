package com.nostrvault.ui.screens

import androidx.compose.animation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.lifecycle.viewModelScope
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

    fun SetupWizardViewModel.setProfileName(value: String) { _profileName.value = value }

    /** Reads the picked image into a JPEG of at most 512 px; same as iOS. */
    fun SetupWizardViewModel.setProfilePhoto(uri: android.net.Uri) {
        viewModelScope.launch(Dispatchers.IO) {
            val jpeg = runCatching { profileJpeg(uri) }.getOrNull()
            withContext(Dispatchers.Main) {
                if (jpeg != null) {
                    _profilePhotoJpeg.value = jpeg
                    _profilePhotoError.value = null
                } else {
                    _profilePhotoError.value = "Couldn't read that photo. Try another."
                }
            }
        }
    }

    /**
     * Decodes [uri] downsampled to at most [maxPixel] on its longest side and
     * re-encodes it as JPEG. A fresh encode carries no EXIF, so the original's
     * location never leaves the phone.
     */
    private fun SetupWizardViewModel.profileJpeg(uri: android.net.Uri, maxPixel: Int = 512): ByteArray? {
        val resolver = appContext.contentResolver
        val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { android.graphics.BitmapFactory.decodeStream(it, null, bounds) }
        val longest = maxOf(bounds.outWidth, bounds.outHeight)
        if (longest <= 0) return null
        var sample = 1
        while (longest / (sample * 2) >= maxPixel) sample *= 2
        val decoded = resolver.openInputStream(uri)?.use {
            android.graphics.BitmapFactory.decodeStream(it, null, android.graphics.BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: return null
        val rotation = resolver.openInputStream(uri)?.use {
            when (androidx.exifinterface.media.ExifInterface(it).getAttributeInt(
                androidx.exifinterface.media.ExifInterface.TAG_ORIENTATION,
                androidx.exifinterface.media.ExifInterface.ORIENTATION_NORMAL,
            )) {
                androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } ?: 0f
        val scale = minOf(1f, maxPixel.toFloat() / maxOf(decoded.width, decoded.height))
        val matrix = android.graphics.Matrix().apply {
            postScale(scale, scale)
            postRotate(rotation)
        }
        val bitmap = android.graphics.Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
        val out = java.io.ByteArrayOutputStream()
        if (!bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, out)) return null
        return out.toByteArray()
    }

    fun SetupWizardViewModel.advanceFromProfile() { _step.value = stepAfter(WizardStep.PROFILE) }

    fun SetupWizardViewModel.skipProfile() {
        _profileName.value = ""
        _profilePhotoJpeg.value = null
        _step.value = stepAfter(WizardStep.PROFILE)
    }

    // ── Account ───────────────────────────────────────────────────
