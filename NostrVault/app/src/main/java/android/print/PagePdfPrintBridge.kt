package android.print

import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import java.io.File

/**
 * Runs a WebView's print adapter straight into a PDF file, with no print
 * dialog. Lives in `android.print` because the layout and write callbacks
 * have package-private constructors. Only for the Share Portal's
 * PagePdfRenderer (a private copy of a web page).
 */
object PagePdfPrintBridge {
    fun write(adapter: PrintDocumentAdapter, attributes: PrintAttributes, out: File, done: (Boolean) -> Unit) {
        val cancel = CancellationSignal()
        adapter.onStart()
        adapter.onLayout(null, attributes, cancel, object : PrintDocumentAdapter.LayoutResultCallback() {
            override fun onLayoutFinished(info: PrintDocumentInfo?, changed: Boolean) {
                val fd = try {
                    ParcelFileDescriptor.open(out, ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_TRUNCATE or ParcelFileDescriptor.MODE_READ_WRITE)
                } catch (_: Exception) {
                    adapter.onFinish(); done(false); return
                }
                adapter.onWrite(arrayOf(PageRange.ALL_PAGES), fd, cancel, object : PrintDocumentAdapter.WriteResultCallback() {
                    override fun onWriteFinished(pages: Array<out PageRange>?) {
                        runCatching { fd.close() }; adapter.onFinish(); done(true)
                    }
                    override fun onWriteFailed(error: CharSequence?) {
                        runCatching { fd.close() }; adapter.onFinish(); done(false)
                    }
                    override fun onWriteCancelled() {
                        runCatching { fd.close() }; adapter.onFinish(); done(false)
                    }
                })
            }
            override fun onLayoutFailed(error: CharSequence?) { adapter.onFinish(); done(false) }
            override fun onLayoutCancelled() { adapter.onFinish(); done(false) }
        }, null)
    }
}
