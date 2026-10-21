package com.nostrvault.ui.screens.profile

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.exifinterface.media.ExifInterface
import com.nostrvault.service.BlossomService
import com.nostrvault.service.MediaPrivacy
import com.nostrvault.ui.theme.*
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import javax.inject.Inject

/** Which Edit Profile field a photo from Photos fills, and how big it is kept. */
enum class ProfilePhotoTarget(val label: String, val longEdge: Int) {
    /** Shown at 72 dp; 1024 px covers every screen density. */
    PICTURE("picture", 1024),
    BANNER("banner", 2400),
}

/** Thrown with the line the Edit Profile sheet shows under the photo buttons. */
class ProfilePhotoUploadException(message: String) : Exception(message)

/** The sizes a picked photo is decoded and saved at. Pure, for tests. */
object ProfilePhotoSizing {
    /** [width] x [height] shrunk so the long side is at most [longEdge]; never enlarged. */
    fun scaled(width: Int, height: Int, longEdge: Int): Pair<Int, Int> {
        val long = maxOf(width, height, 1)
        if (long <= longEdge) return width to height
        val scale = longEdge.toDouble() / long
        return maxOf(1, Math.round(width * scale).toInt()) to maxOf(1, Math.round(height * scale).toInt())
    }

    /**
     * The largest power-of-two decode step that still leaves the long side at
     * least [longEdge], so a 48 MP photo is never held whole in memory.
     */
    fun sampleSize(width: Int, height: Int, longEdge: Int): Int {
        val long = maxOf(width, height)
        var sample = 1
        while (long / (sample * 2) >= longEdge) sample *= 2
        return sample
    }
}

/**
 * Picture and banner from Photos for Edit Profile, as iOS ProfileEditView.upload:
 * the photo is shrunk, saved as a fresh JPEG (which carries no EXIF, so no
 * location) and uploaded to your Blossom servers. The URL goes in the field,
 * the same as pasting one; nothing is published until the sheet saves.
 */
class ProfilePhotoUploader @Inject constructor(
    @ApplicationContext private val context: Context,
    private val blossomService: BlossomService,
) {
    /** The uploaded photo's URL; throws [ProfilePhotoUploadException] with what went wrong. */
    suspend fun upload(uri: Uri, target: ProfilePhotoTarget): String = withContext(Dispatchers.IO) {
        val jpeg = runCatching { jpeg(uri, target.longEdge) }.getOrNull()
            ?: throw ProfilePhotoUploadException(READ_FAILED)
        val file = File.createTempFile("profile_upload_", ".jpg", context.cacheDir)
        try {
            file.writeBytes(jpeg)
            // A re-encoded JPEG has no EXIF; this is the same check every
            // other upload makes, so the rule cannot drift (#335).
            if (!MediaPrivacy.removeLocation(file, JPEG)) throw ProfilePhotoUploadException(MediaPrivacy.FAILURE_MESSAGE)
            val sha256 = blossomService.computeSHA256(file)
            // No local fallback: this URL goes in a public kind 0.
            blossomService.uploadAndMirror(file, sha256, JPEG) ?: throw ProfilePhotoUploadException(UPLOAD_FAILED)
        } finally {
            file.delete()
        }
    }

    /** The photo upright, no longer than [longEdge] on its long side, as JPEG. */
    private fun jpeg(uri: Uri, longEdge: Int): ByteArray? {
        val resolver = context.contentResolver
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) } ?: return null
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val options = BitmapFactory.Options().apply {
            inSampleSize = ProfilePhotoSizing.sampleSize(bounds.outWidth, bounds.outHeight, longEdge)
        }
        val decoded = resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) } ?: return null
        // The new JPEG drops the orientation tag, so turn the pixels instead.
        val rotation = runCatching {
            resolver.openInputStream(uri)?.use { ExifInterface(it).rotationDegrees }
        }.getOrNull() ?: 0
        val (width, height) = ProfilePhotoSizing.scaled(decoded.width, decoded.height, longEdge)
        val matrix = Matrix().apply {
            postScale(width.toFloat() / decoded.width, height.toFloat() / decoded.height)
            if (rotation != 0) postRotate(rotation.toFloat())
        }
        val upright = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
        return ByteArrayOutputStream().use { out ->
            upright.compress(Bitmap.CompressFormat.JPEG, QUALITY, out)
            if (upright !== decoded) upright.recycle()
            decoded.recycle()
            out.toByteArray()
        }
    }

    companion object {
        private const val JPEG = "image/jpeg"
        private const val QUALITY = 88
        const val READ_FAILED = "Couldn't read that photo."
        const val UPLOAD_FAILED = "Couldn't upload that photo. Check your media servers in Settings."
    }
}

/**
 * "Choose picture" and "Choose banner", opening the photo picker. The one
 * uploading shows a spinner; both wait until it is done. iOS photoPickers.
 */
@Composable
internal fun ProfilePhotoButtons(
    uploading: ProfilePhotoTarget?,
    error: String?,
    onPicked: (Uri, ProfilePhotoTarget) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(bottom = 12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            for (target in ProfilePhotoTarget.entries) {
                PhotoButton(target, busy = uploading == target, enabled = uploading == null, onPicked = onPicked,
                    modifier = Modifier.weight(1f))
            }
        }
        if (error != null) {
            Text(error, color = ErrorRed, fontSize = 11.sp)
        }
    }
}

@Composable
private fun PhotoButton(
    target: ProfilePhotoTarget,
    busy: Boolean,
    enabled: Boolean,
    onPicked: (Uri, ProfilePhotoTarget) -> Unit,
    modifier: Modifier = Modifier,
) {
    val accent = LocalNostrVaultColors.current.primary
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) onPicked(uri, target)
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        modifier = modifier
            .heightIn(min = 40.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(accent.copy(alpha = 0.12f))
            .clickable(enabled = enabled, role = Role.Button) {
                picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            }
            .semantics(mergeDescendants = true) {
                contentDescription = if (busy) "Uploading ${target.label}" else "Choose ${target.label} from Photos"
            }
            .padding(horizontal = 12.dp),
    ) {
        if (busy) {
            CircularProgressIndicator(color = accent, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
        } else {
            Icon(NostrVaultIcons.Media, contentDescription = null, tint = accent, modifier = Modifier.size(14.dp))
        }
        Text(
            if (busy) "Uploading…" else "Choose ${target.label}",
            color = if (enabled || busy) accent else SecondaryText,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
    }
}
