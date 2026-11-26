package com.nostrvault.service.media

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.exifinterface.media.ExifInterface
import java.io.File

/**
 * Shrinks a photo before it is uploaded (docs: RESEARCH NV_UPLOAD_COMPRESSION §4.1, Logen 2026-11-26):
 * the long edge at most [LONG_EDGE] px, never enlarged, turned upright, saved as JPEG [JPEG_QUALITY].
 * The new file carries no metadata at all: no location, camera, serial or time.
 *
 * - A JPEG already small enough (≤ [LONG_EDGE] px, ≤ [SMALL_JPEG_BYTES], upright) keeps its pixels;
 *   only its metadata segments are cut out.
 * - A PNG that can be see-through is resized but stays PNG; an opaque one becomes JPEG.
 * - GIFs, animated WebP and HEIC sequences are left as they are (resizing animation is its own job).
 * - HEIC/HEIF always becomes JPEG: most browsers and clients can't show HEIC.
 * - [Quality.ORIGINAL] keeps every byte (the Media tab, your own backup). Location still comes out
 *   afterwards: callers run [com.nostrvault.service.MediaPrivacy.removeLocation] on what this returns,
 *   for every quality, as the last check.
 *
 * Never throws: when the phone can't decode the picture, the original comes back, as before.
 * Apple twin: `Services/MediaCompression/ImageCompressor.swift` (plan A1).
 */
object ImageCompressor {
    enum class Quality { STANDARD, ORIGINAL }

    const val LONG_EDGE = 2048
    const val JPEG_QUALITY = 82
    const val SMALL_JPEG_BYTES = 1_536L * 1024

    const val JPEG = "image/jpeg"
    const val PNG = "image/png"

    private const val TAG = "ImageCompressor"
    private const val HEAD_BYTES = 64 * 1024

    /** The file to upload and its type. [file] is the source itself when nothing was changed. */
    data class Output(val file: File, val mimeType: String)

    /** What to do with one picture. */
    sealed class Plan {
        /** Upload the bytes as they are. */
        object Keep : Plan()
        /** Same pixels, metadata segments cut out. */
        object StripJpeg : Plan()
        /**
         * Decode and save as [format] with the long edge at most [longEdge].
         * [keepIfNotSmaller]: when the new file isn't smaller, keep the source
         * (stripped when it's a JPEG) instead.
         */
        data class Encode(val format: Format, val longEdge: Int, val keepIfNotSmaller: Boolean) : Plan()
    }

    enum class Format(val mimeType: String, val compress: Bitmap.CompressFormat) {
        JPEG(ImageCompressor.JPEG, Bitmap.CompressFormat.JPEG),
        PNG(ImageCompressor.PNG, Bitmap.CompressFormat.PNG),
    }

    /** What the picture is, as far as [plan] needs to know. */
    data class Source(
        val mimeType: String,
        /** Pixels as stored (before turning); 0 when unknown. */
        val width: Int,
        val height: Int,
        val bytes: Long,
        /** EXIF says to turn it. */
        val rotated: Boolean,
        val animated: Boolean,
        /** For a PNG: whether it can be see-through. */
        val pngAlpha: Boolean,
    )

    private val ENCODABLE = setOf(JPEG, "image/jpg", "image/pjpeg", PNG, "image/webp", "image/bmp", "image/x-ms-bmp")

    /** The rules of §4.1. Pure, for tests. */
    fun plan(source: Source, quality: Quality): Plan {
        if (quality == Quality.ORIGINAL || source.animated) return Plan.Keep
        val type = ImageHeaders.bareType(source.mimeType)
        val heic = ImageHeaders.isHeic(type)
        if (!heic && type !in ENCODABLE) return Plan.Keep
        if (source.width <= 0 || source.height <= 0) return Plan.Keep
        val fits = maxOf(source.width, source.height) <= LONG_EDGE
        if (type == PNG && source.pngAlpha) {
            return if (fits) Plan.Keep else Plan.Encode(Format.PNG, LONG_EDGE, keepIfNotSmaller = false)
        }
        val jpeg = type == JPEG || type == "image/jpg" || type == "image/pjpeg"
        if (jpeg && fits && !source.rotated && source.bytes <= SMALL_JPEG_BYTES) return Plan.StripJpeg
        // A HEIC must change (no one can show it); a small picture that would grow keeps its bytes.
        return Plan.Encode(Format.JPEG, LONG_EDGE, keepIfNotSmaller = !heic && fits && !source.rotated)
    }

    /** [width] x [height] shrunk so the long side is at most [longEdge]; never enlarged. */
    fun scaled(width: Int, height: Int, longEdge: Int): Pair<Int, Int> {
        val long = maxOf(width, height, 1)
        if (long <= longEdge) return width to height
        val scale = longEdge.toDouble() / long
        return maxOf(1, Math.round(width * scale).toInt()) to maxOf(1, Math.round(height * scale).toInt())
    }

    /** The largest power-of-two decode step that still leaves the long side at least [longEdge]. */
    fun sampleSize(width: Int, height: Int, longEdge: Int): Int {
        val long = maxOf(width, height)
        var sample = 1
        while (long / (sample * 2) >= longEdge) sample *= 2
        return sample
    }

    /**
     * [source] ready to upload, written next to it in [workDir] when it changes. The caller
     * deletes both files when done ([Output.file] may be [source]).
     */
    fun compress(source: File, mimeType: String, quality: Quality, workDir: File): Output {
        // A video or other file isn't opened at all.
        if (quality == Quality.ORIGINAL || !ImageHeaders.bareType(mimeType).startsWith("image/")) return Output(source, mimeType)
        return try {
            run(source, mimeType, describe(source, mimeType), workDir)
        } catch (e: Throwable) {
            Log.w(TAG, "Couldn't shrink $mimeType, keeping the original: ${e.message}")
            Output(source, mimeType)
        }
    }

    /** [compress], deleting [source] when a new file takes its place. */
    fun replacing(source: File, mimeType: String, quality: Quality, workDir: File): Output =
        compress(source, mimeType, quality, workDir).also { if (it.file != source) source.delete() }

    private fun run(source: File, mimeType: String, info: Source, workDir: File): Output {
        return when (val plan = plan(info, Quality.STANDARD)) {
            Plan.Keep -> Output(source, mimeType)
            Plan.StripJpeg -> stripped(source, workDir)?.let { Output(it, JPEG) }
                ?: encoded(source, Plan.Encode(Format.JPEG, LONG_EDGE, keepIfNotSmaller = false), info, workDir)
                ?: Output(source, mimeType)
            is Plan.Encode -> {
                val out = encoded(source, plan, info, workDir) ?: return Output(source, mimeType)
                if (!plan.keepIfNotSmaller || out.file.length() < source.length()) return out
                out.file.delete()
                val jpeg = ImageHeaders.bareType(mimeType).let { it == JPEG || it == "image/jpg" || it == "image/pjpeg" }
                (if (jpeg) stripped(source, workDir)?.let { Output(it, JPEG) } else null) ?: Output(source, mimeType)
            }
        }
    }

    /** Reads the type, size, turn and animation of [file]. */
    internal fun describe(file: File, mimeType: String): Source {
        val head = file.inputStream().use { s -> ByteArray(HEAD_BYTES).let { b -> b.copyOf(maxOf(0, s.read(b))) } }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        var width = bounds.outWidth
        var height = bounds.outHeight
        if ((width <= 0 || height <= 0) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            headerSize(file)?.let { (w, h) -> width = w; height = h }
        }
        val rotation = runCatching { ExifInterface(file).rotationDegrees }.getOrDefault(0)
        val animated = ImageHeaders.isGif(head) || ImageHeaders.isAnimatedWebp(head) ||
            ImageHeaders.isHeicSequence(mimeType)
        return Source(mimeType, width, height, file.length(), rotation != 0, animated,
            pngAlpha = ImageHeaders.pngHasAlpha(head) ?: false)
    }

    @RequiresApi(Build.VERSION_CODES.P)
    private fun headerSize(file: File): Pair<Int, Int>? = runCatching {
        var size: Pair<Int, Int>? = null
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
            size = info.size.width to info.size.height
            // Only the header was wanted; a tiny target keeps the decode cheap.
            decoder.setTargetSize(1, 1)
        }.recycle()
        size
    }.getOrNull()

    private fun stripped(source: File, workDir: File): File? {
        val bytes = ImageHeaders.jpegWithoutMetadata(source.readBytes()) ?: return null
        return File.createTempFile("compressed_", ".jpg", workDir).apply { writeBytes(bytes) }
    }

    private fun encoded(source: File, plan: Plan.Encode, info: Source, workDir: File): Output? {
        val bitmap = decodeUpright(source, plan.longEdge, info) ?: return null
        val out = File.createTempFile("compressed_", if (plan.format == Format.PNG) ".png" else ".jpg", workDir)
        val written = try {
            out.outputStream().use { bitmap.compress(plan.format.compress, JPEG_QUALITY, it) }
        } finally {
            bitmap.recycle()
        }
        if (!written || out.length() == 0L) {
            out.delete()
            return null
        }
        return Output(out, plan.format.mimeType)
    }

    /** The picture turned upright, no longer than [longEdge] on its long side. Null when it can't be read. */
    private fun decodeUpright(source: File, longEdge: Int, info: Source): Bitmap? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) decodeWithImageDecoder(source, longEdge)
        else decodeWithBitmapFactory(source, longEdge, info)

    /** ImageDecoder samples while it reads (a 48 MP photo is never held whole) and applies the turn itself. */
    @RequiresApi(Build.VERSION_CODES.P)
    private fun decodeWithImageDecoder(source: File, longEdge: Int): Bitmap? = runCatching {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(source)) { decoder, info, _ ->
            // Bitmap.compress needs a software bitmap.
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            // Target and size are in the same (upright) space, so the aspect holds either way.
            val (w, h) = scaled(info.size.width, info.size.height, longEdge)
            if (w != info.size.width || h != info.size.height) decoder.setTargetSize(w, h)
        }
    }.onFailure { Log.w(TAG, "ImageDecoder failed: ${it.message}") }.getOrNull()

    /** Android 8.x: sample, scale, then turn by the EXIF tag (the new file has no EXIF to say so). */
    private fun decodeWithBitmapFactory(source: File, longEdge: Int, info: Source): Bitmap? {
        val options = BitmapFactory.Options().apply { inSampleSize = sampleSize(info.width, info.height, longEdge) }
        val decoded = BitmapFactory.decodeFile(source.absolutePath, options) ?: return null
        val rotation = runCatching { ExifInterface(source).rotationDegrees }.getOrDefault(0)
        val (w, h) = scaled(decoded.width, decoded.height, longEdge)
        if (rotation == 0 && w == decoded.width && h == decoded.height) return decoded
        val matrix = Matrix().apply {
            postScale(w.toFloat() / decoded.width, h.toFloat() / decoded.height)
            if (rotation != 0) postRotate(rotation.toFloat())
        }
        val upright = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
        if (upright !== decoded) decoded.recycle()
        return upright
    }
}
