package com.nostrvault.service.media

import com.nostrvault.service.media.ImageCompressor.Format
import com.nostrvault.service.media.ImageCompressor.Plan
import com.nostrvault.service.media.ImageCompressor.Quality
import com.nostrvault.service.media.ImageCompressor.Source
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ImageCompressorTest {
    private fun source(
        mime: String = "image/jpeg",
        width: Int = 4032,
        height: Int = 3024,
        bytes: Long = 3_000_000,
        rotated: Boolean = false,
        animated: Boolean = false,
        alpha: Boolean = false,
    ) = Source(mime, width, height, bytes, rotated, animated, alpha)

    private val shrinkToJpeg = Plan.Encode(Format.JPEG, 2048, keepIfNotSmaller = false)

    // Logen 2026-11-26: 2048 px, JPEG 82.
    @Test fun numbersAreLogensCalls() {
        assertEquals(2048, ImageCompressor.LONG_EDGE)
        assertEquals(82, ImageCompressor.JPEG_QUALITY)
    }

    @Test fun bigJpegIsShrunk() = assertEquals(shrinkToJpeg, ImageCompressor.plan(source(), Quality.STANDARD))

    @Test fun originalKeepsEveryByte() {
        assertEquals(Plan.Keep, ImageCompressor.plan(source(), Quality.ORIGINAL))
        assertEquals(Plan.Keep, ImageCompressor.plan(source(mime = "image/heic"), Quality.ORIGINAL))
    }

    @Test fun smallUprightJpegOnlyLosesItsMetadata() =
        assertEquals(Plan.StripJpeg, ImageCompressor.plan(source(width = 2048, height = 1536, bytes = 900_000), Quality.STANDARD))

    @Test fun smallJpegOverTheByteLimitIsReEncodedButKeptIfItWouldGrow() =
        assertEquals(Plan.Encode(Format.JPEG, 2048, keepIfNotSmaller = true),
            ImageCompressor.plan(source(width = 2000, height = 1500, bytes = 2_000_000), Quality.STANDARD))

    /** Its turn lives in the EXIF the strip would drop, so it's re-encoded upright, whatever the size. */
    @Test fun smallTurnedJpegIsReEncoded() =
        assertEquals(shrinkToJpeg, ImageCompressor.plan(source(width = 1600, height = 1200, bytes = 400_000, rotated = true), Quality.STANDARD))

    @Test fun heicAlwaysBecomesJpeg() {
        assertEquals(shrinkToJpeg, ImageCompressor.plan(source(mime = "image/heic"), Quality.STANDARD))
        assertEquals(shrinkToJpeg, ImageCompressor.plan(source(mime = "image/HEIF", width = 800, height = 600, bytes = 50_000), Quality.STANDARD))
    }

    @Test fun animationsAreLeftAlone() {
        assertEquals(Plan.Keep, ImageCompressor.plan(source(mime = "image/gif", animated = true), Quality.STANDARD))
        assertEquals(Plan.Keep, ImageCompressor.plan(source(mime = "image/webp", animated = true), Quality.STANDARD))
    }

    @Test fun seeThroughPngStaysPng() {
        assertEquals(Plan.Encode(Format.PNG, 2048, keepIfNotSmaller = false),
            ImageCompressor.plan(source(mime = "image/png", alpha = true), Quality.STANDARD))
        assertEquals(Plan.Keep, ImageCompressor.plan(source(mime = "image/png", width = 1200, height = 800, alpha = true), Quality.STANDARD))
    }

    @Test fun opaquePngAndStillWebpBecomeJpeg() {
        assertEquals(shrinkToJpeg, ImageCompressor.plan(source(mime = "image/png"), Quality.STANDARD))
        assertEquals(shrinkToJpeg, ImageCompressor.plan(source(mime = "image/webp"), Quality.STANDARD))
        assertEquals(Plan.Encode(Format.JPEG, 2048, keepIfNotSmaller = true),
            ImageCompressor.plan(source(mime = "image/png", width = 600, height = 400, bytes = 90_000), Quality.STANDARD))
    }

    @Test fun notAPictureWeCanDrawIsKept() {
        assertEquals(Plan.Keep, ImageCompressor.plan(source(mime = "video/mp4"), Quality.STANDARD))
        assertEquals(Plan.Keep, ImageCompressor.plan(source(mime = "image/avif"), Quality.STANDARD))
        assertEquals(Plan.Keep, ImageCompressor.plan(source(mime = "application/octet-stream"), Quality.STANDARD))
        assertEquals(Plan.Keep, ImageCompressor.plan(source(width = 0, height = 0), Quality.STANDARD))
    }

    @Test fun scaledNeverEnlargesAndKeepsAspect() {
        assertEquals(2048 to 1536, ImageCompressor.scaled(4032, 3024, 2048))
        assertEquals(1536 to 2048, ImageCompressor.scaled(6000, 8000, 2048))
        assertEquals(800 to 600, ImageCompressor.scaled(800, 600, 2048))
        assertEquals(2048 to 1, ImageCompressor.scaled(10_000, 2, 2048))
    }

    @Test fun sampleSizeStaysAtOrAboveTheEdge() {
        assertEquals(1, ImageCompressor.sampleSize(4000, 3000, 2048))
        assertEquals(2, ImageCompressor.sampleSize(4096, 3072, 2048))
        assertEquals(2, ImageCompressor.sampleSize(8000, 6000, 2048))
        assertEquals(4, ImageCompressor.sampleSize(8192, 6144, 2048))
    }

    // Headers

    @Test fun heicTypes() {
        assertTrue(ImageHeaders.isHeic("image/heic"))
        assertTrue(ImageHeaders.isHeic("image/HEIF"))
        assertTrue(ImageHeaders.isHeic("image/heic; charset=binary"))
        assertTrue(ImageHeaders.isHeicSequence("image/heic-sequence"))
        assertFalse(ImageHeaders.isHeicSequence("image/heic"))
        assertFalse(ImageHeaders.isHeic("image/jpeg"))
        assertFalse(ImageHeaders.isHeic("image/avif"))
    }

    @Test fun gifByItsHeader() {
        assertTrue(ImageHeaders.isGif("GIF89a".toByteArray()))
        assertFalse(ImageHeaders.isGif(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte())))
    }

    private fun webp(flags: Int): ByteArray =
        "RIFF".toByteArray() + ByteArray(4) + "WEBPVP8X".toByteArray() + ByteArray(4) + byteArrayOf(flags.toByte()) + ByteArray(9)

    @Test fun animatedWebpByItsFlag() {
        assertTrue(ImageHeaders.isAnimatedWebp(webp(0x02)))
        assertTrue(ImageHeaders.isAnimatedWebp(webp(0x12)))
        assertFalse(ImageHeaders.isAnimatedWebp(webp(0x10)))
        assertFalse(ImageHeaders.isAnimatedWebp("RIFF\u0000\u0000\u0000\u0000WEBPVP8 ".toByteArray() + ByteArray(10)))
    }

    private fun chunk(type: String, data: ByteArray = ByteArray(0)): ByteArray {
        val n = data.size
        return byteArrayOf((n ushr 24).toByte(), (n ushr 16).toByte(), (n ushr 8).toByte(), n.toByte()) +
            type.toByteArray() + data + ByteArray(4)
    }

    private fun png(colourType: Int, vararg extra: ByteArray): ByteArray {
        val ihdr = ByteArray(13).also { it[8] = 8; it[9] = colourType.toByte() }
        var out = byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte(), 0x0D, 0x0A, 0x1A, 0x0A) + chunk("IHDR", ihdr)
        extra.forEach { out += it }
        return out + chunk("IDAT", ByteArray(8)) + chunk("IEND")
    }

    @Test fun pngAlpha() {
        assertEquals(true, ImageHeaders.pngHasAlpha(png(6)))
        assertEquals(true, ImageHeaders.pngHasAlpha(png(4)))
        assertEquals(false, ImageHeaders.pngHasAlpha(png(2)))
        assertEquals(true, ImageHeaders.pngHasAlpha(png(3, chunk("PLTE", ByteArray(6)), chunk("tRNS", ByteArray(2)))))
        assertEquals(false, ImageHeaders.pngHasAlpha(png(3, chunk("PLTE", ByteArray(6)))))
        assertNull(ImageHeaders.pngHasAlpha("GIF89a".toByteArray() + ByteArray(30)))
    }

    // JPEG metadata strip

    private fun segment(marker: Int, data: ByteArray): ByteArray {
        val n = data.size + 2
        return byteArrayOf(0xFF.toByte(), marker.toByte(), (n ushr 8).toByte(), n.toByte()) + data
    }

    private val soi = byteArrayOf(0xFF.toByte(), 0xD8.toByte())
    private val app0 = segment(0xE0, "JFIF\u0000\u0001\u0001".toByteArray())
    private val exif = segment(0xE1, "Exif\u0000\u0000GPS-and-serial".toByteArray())
    private val xmp = segment(0xE1, "http://ns.adobe.com/xap/1.0/\u0000<x:GPSLatitude/>".toByteArray())
    private val icc = segment(0xE2, "ICC_PROFILE\u0000\u0001\u0001profile".toByteArray())
    private val mpf = segment(0xE2, "MPF\u0000more".toByteArray())
    private val iptc = segment(0xED, "Photoshop 3.0\u0000iptc".toByteArray())
    private val adobe = segment(0xEE, "Adobe\u0000d".toByteArray())
    private val comment = segment(0xFE, "made by a camera".toByteArray())
    private val dqt = segment(0xDB, ByteArray(65))
    private val sof = segment(0xC0, ByteArray(15))
    private val sos = segment(0xDA, ByteArray(10)) + byteArrayOf(0x12, 0xFF.toByte(), 0x00, 0x34, 0xFF.toByte(), 0xD0.toByte(), 0x56)
    private val eoi = byteArrayOf(0xFF.toByte(), 0xD9.toByte())

    @Test fun stripKeepsLookDropsMetadataAndTrailer() {
        val trailer = soi + exif + eoi // a second picture after the first, as MPF/gain maps add
        val jpeg = soi + app0 + exif + xmp + icc + mpf + iptc + adobe + comment + dqt + sof + sos + eoi + trailer
        val stripped = ImageHeaders.jpegWithoutMetadata(jpeg)!!
        assertEquals((soi + app0 + icc + adobe + dqt + sof + sos + eoi).toList(), stripped.toList())
    }

    @Test fun stripOfACleanJpegChangesNothing() {
        val jpeg = soi + app0 + dqt + sof + sos + eoi
        assertEquals(jpeg.toList(), ImageHeaders.jpegWithoutMetadata(jpeg)!!.toList())
    }

    @Test fun stripRefusesWhatItCantWalk() {
        assertNull(ImageHeaders.jpegWithoutMetadata("not a jpeg".toByteArray()))
        assertNull(ImageHeaders.jpegWithoutMetadata(soi + byteArrayOf(0xFF.toByte(), 0xE1.toByte(), 0x7F, 0x00)))
        assertNull(ImageHeaders.jpegWithoutMetadata(soi + app0 + sos)) // no end marker
    }

    // Callers

    @Test fun aVideoOrOtherFileIsNeverOpenedAndNeverDeleted() {
        val video = java.io.File.createTempFile("clip", ".mp4").apply { writeBytes(ByteArray(16)) }
        try {
            val out = ImageCompressor.replacing(video, "video/mp4", Quality.STANDARD, video.parentFile!!)
            assertEquals(ImageCompressor.Output(video, "video/mp4"), out)
            assertTrue(video.exists())
        } finally {
            video.delete()
        }
    }

    @Test fun originalHandsBackTheSameFile() {
        val photo = java.io.File.createTempFile("photo", ".jpg").apply { writeBytes(ByteArray(16)) }
        try {
            assertEquals(ImageCompressor.Output(photo, "image/heic"),
                ImageCompressor.replacing(photo, "image/heic", Quality.ORIGINAL, photo.parentFile!!))
            assertTrue(photo.exists())
        } finally {
            photo.delete()
        }
    }
}
