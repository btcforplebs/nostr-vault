package com.nostrvault.service

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.nio.ByteBuffer

/**
 * Removes where a photo or video was taken before it is uploaded (iOS #335,
 * `MediaPrivacy.swift`). A Blossom blob is public and content-addressed: once
 * a mirror has it, a GPS fix in it cannot be taken back.
 *
 * Only files that actually carry a location are rewritten, so a GIF keeps its
 * animation and an ordinary photo uploads byte for byte. When a location is
 * found and cannot be removed the caller must not upload: the rule is "never
 * send a location", not "try to".
 *
 * Android already redacts the location from photos read through MediaStore
 * and the photo picker (the app does not hold ACCESS_MEDIA_LOCATION), but a
 * file shared from another app's own provider or a document picker arrives
 * whole, so every upload goes through here.
 */
object MediaPrivacy {
    private const val TAG = "MediaPrivacy"

    /** Shown when a file has a location that could not be removed. */
    const val FAILURE_MESSAGE = "Couldn't remove the location from this file, so it wasn't uploaded."

    /**
     * Removes any location from [file] in place. True when the file is now
     * safe to upload: it had no location, one was removed, or it is not a
     * format that can be read here. False when a location is there and could
     * not be removed; the file must not be uploaded.
     */
    fun removeLocation(file: File, contentType: String): Boolean {
        val type = contentType.lowercase()
        return when {
            type.startsWith("image/") -> removeImageLocation(file, type)
            type.startsWith("video/") -> removeVideoLocation(file)
            else -> true
        }
    }

    // Images

    /** Every EXIF GPS tag; any one of them can place the photo. */
    private val GPS_TAGS = listOf(
        ExifInterface.TAG_GPS_VERSION_ID,
        ExifInterface.TAG_GPS_LATITUDE_REF, ExifInterface.TAG_GPS_LATITUDE,
        ExifInterface.TAG_GPS_LONGITUDE_REF, ExifInterface.TAG_GPS_LONGITUDE,
        ExifInterface.TAG_GPS_ALTITUDE_REF, ExifInterface.TAG_GPS_ALTITUDE,
        ExifInterface.TAG_GPS_TIMESTAMP, ExifInterface.TAG_GPS_SATELLITES,
        ExifInterface.TAG_GPS_STATUS, ExifInterface.TAG_GPS_MEASURE_MODE,
        ExifInterface.TAG_GPS_DOP, ExifInterface.TAG_GPS_SPEED_REF, ExifInterface.TAG_GPS_SPEED,
        ExifInterface.TAG_GPS_TRACK_REF, ExifInterface.TAG_GPS_TRACK,
        ExifInterface.TAG_GPS_IMG_DIRECTION_REF, ExifInterface.TAG_GPS_IMG_DIRECTION,
        ExifInterface.TAG_GPS_MAP_DATUM,
        ExifInterface.TAG_GPS_DEST_LATITUDE_REF, ExifInterface.TAG_GPS_DEST_LATITUDE,
        ExifInterface.TAG_GPS_DEST_LONGITUDE_REF, ExifInterface.TAG_GPS_DEST_LONGITUDE,
        ExifInterface.TAG_GPS_DEST_BEARING_REF, ExifInterface.TAG_GPS_DEST_BEARING,
        ExifInterface.TAG_GPS_DEST_DISTANCE_REF, ExifInterface.TAG_GPS_DEST_DISTANCE,
        ExifInterface.TAG_GPS_PROCESSING_METHOD, ExifInterface.TAG_GPS_AREA_INFORMATION,
        ExifInterface.TAG_GPS_DATESTAMP, ExifInterface.TAG_GPS_DIFFERENTIAL,
        ExifInterface.TAG_GPS_H_POSITIONING_ERROR,
    )

    /** GPS in the EXIF block or in XMP. */
    internal fun imageHasLocation(exif: ExifInterface): Boolean =
        GPS_TAGS.any { exif.getAttribute(it) != null } || xmpHasLocation(exif.getAttribute(ExifInterface.TAG_XMP))

    internal fun xmpHasLocation(xmp: String?): Boolean =
        xmp != null && (xmp.contains("GPSLatitude") || xmp.contains("GPSLongitude"))

    private fun removeImageLocation(file: File, type: String): Boolean {
        val exif = try {
            ExifInterface(file)
        } catch (e: Exception) {
            // Not an image ExifInterface can read (GIF, AVIF…): nothing to
            // check or rewrite here. Upload as before.
            return true
        }
        if (!imageHasLocation(exif)) return true
        // ExifInterface rewrites JPEG, PNG and WebP; HEIC and DNG it only reads.
        if (!ExifInterface.isSupportedMimeType(type) || type == "image/heic" || type == "image/heif") {
            Log.w(TAG, "$type has a location and can't be rewritten here")
            return false
        }
        return try {
            if (GPS_TAGS.any { exif.getAttribute(it) != null }) {
                GPS_TAGS.forEach { exif.setAttribute(it, null) }
                exif.saveAttributes()
            }
            // ExifInterface rewrites only the EXIF block of a JPEG; XMP rides
            // in its own segment, so a location there is cut out separately.
            if (xmpHasLocation(ExifInterface(file).getAttribute(ExifInterface.TAG_XMP)) && type == "image/jpeg") {
                file.writeBytes(jpegWithoutXmp(file.readBytes()) ?: return false)
            }
            // Read back what was written: only a clean file goes up.
            !imageHasLocation(ExifInterface(file))
        } catch (e: Exception) {
            Log.w(TAG, "Couldn't remove the location from $type: ${e.message}")
            false
        }
    }

    private val XMP_HEADERS = listOf("http://ns.adobe.com/xap/1.0/\u0000", "http://ns.adobe.com/xmp/extension/\u0000")
        .map { it.toByteArray(Charsets.ISO_8859_1) }

    /**
     * [jpeg] with its XMP segments (APP1 starting with an XMP namespace) left
     * out and every other byte kept. Null when the segments can't be walked.
     */
    internal fun jpegWithoutXmp(jpeg: ByteArray): ByteArray? {
        fun u8(i: Int) = jpeg[i].toInt() and 0xFF
        if (jpeg.size < 4 || u8(0) != 0xFF || u8(1) != 0xD8) return null
        val out = java.io.ByteArrayOutputStream(jpeg.size)
        out.write(jpeg, 0, 2)
        var i = 2
        while (i + 4 <= jpeg.size) {
            if (u8(i) != 0xFF) return null
            val marker = u8(i + 1)
            // Start of scan: the rest is image data, copied as is.
            if (marker == 0xDA) break
            val length = (u8(i + 2) shl 8) or u8(i + 3)
            val end = i + 2 + length
            if (length < 2 || end > jpeg.size) return null
            val isXmp = marker == 0xE1 && XMP_HEADERS.any { h ->
                i + 4 + h.size <= end && (h.indices).all { jpeg[i + 4 + it] == h[it] }
            }
            if (!isXmp) out.write(jpeg, i, end - i)
            i = end
        }
        out.write(jpeg, i, jpeg.size - i)
        return out.toByteArray()
    }

    // Videos

    /** Null when the file can't be read as a video at all. */
    private fun videoHasLocation(file: File): Boolean? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            // The `©xyz` / ISO 6709 location an MP4 or MOV carries.
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION) != null
        } catch (e: Exception) {
            null
        } finally {
            retriever.release()
        }
    }

    private fun removeVideoLocation(file: File): Boolean {
        // Unreadable here (WebM in an odd wrapper, MKV…): it can be neither
        // checked nor rewritten. Upload as before, as iOS does.
        val hasLocation = videoHasLocation(file) ?: return true
        if (!hasLocation) return true
        val out = File(file.parentFile, "noloc_${file.name}.mp4")
        return try {
            remuxWithoutMetadata(file, out)
            if (videoHasLocation(out) != false) {
                out.delete()
                false
            } else {
                out.renameTo(file) || run { out.copyTo(file, overwrite = true); out.delete(); true }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Couldn't remove the location from a video: ${e.message}")
            out.delete()
            false
        }
    }

    /**
     * Copies every audio and video stream into a new MP4 without re-encoding,
     * so quality and size stay the same. MediaMuxer writes no location unless
     * asked to. Any stream it can't take fails the whole copy: a video that
     * lost its sound is not a clean copy of it.
     */
    private fun remuxWithoutMetadata(source: File, out: File) {
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            extractor.setDataSource(source.absolutePath)
            muxer = MediaMuxer(out.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val rotation = MediaMetadataRetriever().let { r ->
                try {
                    r.setDataSource(source.absolutePath)
                    r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                } finally {
                    r.release()
                }
            }
            val tracks = HashMap<Int, Int>()
            var bufferSize = 1 shl 20
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("video/") && !mime.startsWith("audio/")) continue
                tracks[i] = muxer.addTrack(format)
                extractor.selectTrack(i)
                if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                    bufferSize = maxOf(bufferSize, format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
                }
            }
            check(tracks.isNotEmpty()) { "no streams" }
            muxer.setOrientationHint(rotation)
            muxer.start()
            val buffer = ByteBuffer.allocate(bufferSize)
            val info = MediaCodec.BufferInfo()
            while (true) {
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                val keyFrame = extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0
                info.set(0, size, extractor.sampleTime, if (keyFrame) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                tracks[extractor.sampleTrackIndex]?.let { muxer.writeSampleData(it, buffer, info) }
                extractor.advance()
            }
            muxer.stop()
        } finally {
            muxer?.release()
            extractor.release()
        }
    }
}
