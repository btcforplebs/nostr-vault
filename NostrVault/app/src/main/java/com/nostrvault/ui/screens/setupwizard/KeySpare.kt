package com.nostrvault.ui.screens

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PrintManager
import android.print.pdf.PrintedPdfDocument
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeEncoder
import java.io.FileOutputStream

/**
 * The spare copy of a new key (setup screens r3, "Keep a spare"): a paper
 * card, or the key copied ([copySecretKey]). Twin of iOS KeySpare (#2416).
 *
 * The app writes no file: the card is drawn in memory and handed to the
 * system print framework, which renders it into the descriptor the print
 * spooler gives us. The system's own "Save as PDF" printer can still save
 * the card; the step's text asks for paper only. No Save to Passwords
 * (Tod 2026-11-22).
 */
internal object KeySpare {
    const val JOB_NAME = "Nostr key card"

    /**
     * Opens the system print dialog with the paper card. [onSent] is called
     * once the dialog closes, true when this job reached the print queue (or
     * finished), false when it was cancelled or failed. Android does not say
     * whether paper came out, so the step never counts this as the spare on
     * its own: "I saved my secret key" still has to be ticked.
     */
    fun printCard(context: Context, name: String, npub: String, nsec: String, onSent: (Boolean) -> Unit) {
        val card = runCatching { paperCard(name, npub, nsec) }.getOrNull() ?: return onSent(false)
        val manager = context.getSystemService(Context.PRINT_SERVICE) as? PrintManager ?: return onSent(false)
        var job: android.print.PrintJob? = null
        val adapter = CardAdapter(context, card) {
            card.recycle()
            val j = job
            onSent(j != null && (j.isQueued || j.isStarted || j.isCompleted))
        }
        val attributes = PrintAttributes.Builder()
            .setColorMode(PrintAttributes.COLOR_MODE_MONOCHROME)
            .setMediaSize(PrintAttributes.MediaSize.ISO_A4)
            .build()
        job = runCatching { manager.print(JOB_NAME, adapter, attributes) }.getOrNull()
        if (job == null) { card.recycle(); onSent(false) }
    }

    /** One page: the card centred near the top, at its drawn size. */
    private class CardAdapter(
        private val context: Context,
        private val card: Bitmap,
        private val onDone: () -> Unit,
    ) : PrintDocumentAdapter() {
        private var attributes: PrintAttributes? = null

        override fun onLayout(
            old: PrintAttributes?, new: PrintAttributes, cancel: CancellationSignal,
            callback: LayoutResultCallback, extras: Bundle?,
        ) {
            if (cancel.isCanceled) return callback.onLayoutCancelled()
            attributes = new
            val info = PrintDocumentInfo.Builder("nostr-key-card.pdf")
                .setContentType(PrintDocumentInfo.CONTENT_TYPE_PHOTO)
                .setPageCount(1)
                .build()
            callback.onLayoutFinished(info, new != old)
        }

        override fun onWrite(
            pages: Array<out PageRange>, destination: ParcelFileDescriptor,
            cancel: CancellationSignal, callback: WriteResultCallback,
        ) {
            val pdf = PrintedPdfDocument(context, attributes ?: return callback.onWriteFailed(null))
            try {
                val page = pdf.startPage(0)
                val canvas = page.canvas
                // PDF points: fit the card into the page width with a margin.
                val margin = 36f
                val width = canvas.width - 2 * margin
                val scale = minOf(1f, width / card.width)
                val left = (canvas.width - card.width * scale) / 2
                canvas.drawBitmap(card, null, RectF(left, margin, left + card.width * scale, margin + card.height * scale), Paint(Paint.FILTER_BITMAP_FLAG))
                pdf.finishPage(page)
                if (cancel.isCanceled) return callback.onWriteCancelled()
                FileOutputStream(destination.fileDescriptor).use { pdf.writeTo(it) }
                callback.onWriteFinished(arrayOf(PageRange.ALL_PAGES))
            } catch (e: Exception) {
                callback.onWriteFailed(e.message)
            } finally {
                pdf.close()
            }
        }

        override fun onFinish() = onDone()
    }

    /**
     * The printed spare: black on white, a QR of the secret key and the key
     * in full, so either can be typed or scanned back in. Same text as iOS
     * PaperKeyCard. Drawn at 2x for a sharp print.
     */
    fun paperCard(name: String, npub: String, nsec: String): Bitmap {
        val s = 2f
        val w = (480 * s).toInt()
        val pad = 22 * s
        val qrSize = (150 * s).toInt()
        val bold = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.BLACK; typeface = Typeface.DEFAULT_BOLD }
        val mono = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.BLACK; typeface = Typeface.MONOSPACE }
        val plain = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.BLACK }
        val textLeft = pad + qrSize + 16 * s
        val textWidth = (w - textLeft - pad).toInt()
        fun layout(text: String, paint: TextPaint, size: Float, width: Int): StaticLayout {
            val p = TextPaint(paint).apply { textSize = size * s }
            return StaticLayout.Builder.obtain(text, 0, text.length, p, width).setAlignment(Layout.Alignment.ALIGN_NORMAL).build()
        }
        val trimmed = name.trim()
        val nameLayout = trimmed.takeIf { it.isNotEmpty() }?.let { layout(it, bold, 22f, (w - 2 * pad).toInt()) }
        val secretLabel = layout("Secret key", bold, 11f, textWidth)
        val secret = layout(nsec, mono, 11f, textWidth)
        val publicLabel = layout("Public key", bold, 11f, textWidth)
        val public = layout(npub, mono, 9f, textWidth)
        val warning = layout(
            "Anyone with this card can post as you. Nobody can recover the key for you. Store it like a passport.",
            plain, 11f, (w - 2 * pad).toInt(),
        )
        val headerH = 13 * s + 14 * s
        val nameH = nameLayout?.let { it.height + 14 * s } ?: 0f
        val keysH = secretLabel.height + 8 * s + secret.height + 12 * s + publicLabel.height + 8 * s + public.height
        val bodyH = maxOf(qrSize.toFloat(), keysH)
        val h = (pad + headerH + nameH + bodyH + 14 * s + warning.height + pad).toInt()

        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(bitmap)
        c.drawColor(android.graphics.Color.WHITE)
        val frame = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 2 * s; color = android.graphics.Color.BLACK }
        c.drawRoundRect(RectF(4 * s, 4 * s, w - 4 * s, h - 4 * s), 14 * s, 14 * s, frame)

        var y = pad
        val header = TextPaint(bold).apply { textSize = 13 * s; letterSpacing = 0.1f }
        c.drawText("NOSTR VAULT · SECRET KEY", pad, y + 13 * s, header)
        val stamp = TextPaint(bold).apply { textSize = 11 * s }
        val stampText = "KEEP SAFE"
        val stampW = stamp.measureText(stampText) + 16 * s
        val stampBox = RectF(w - pad - stampW, y - 3 * s, w - pad, y + 15 * s)
        c.drawRoundRect(stampBox, 4 * s, 4 * s, Paint(frame).apply { strokeWidth = 1.5f * s })
        c.drawText(stampText, stampBox.left + 8 * s, y + 11 * s, stamp)
        y += headerH
        nameLayout?.let { c.save(); c.translate(pad, y); it.draw(c); c.restore(); y += nameH }

        BarcodeEncoder().encodeBitmap(nsec, BarcodeFormat.QR_CODE, qrSize, qrSize).let { qr ->
            c.drawBitmap(qr, pad, y, null)
            qr.recycle()
        }
        var ty = y
        for ((l, gap) in listOf(secretLabel to 8 * s, secret to 12 * s, publicLabel to 8 * s, public to 0f)) {
            c.save(); c.translate(textLeft, ty); l.draw(c); c.restore()
            ty += l.height + gap
        }
        y += bodyH + 14 * s
        c.save(); c.translate(pad, y); warning.draw(c); c.restore()
        return bitmap
    }
}
