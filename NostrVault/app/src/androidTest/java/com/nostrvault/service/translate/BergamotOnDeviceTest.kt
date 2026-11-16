package com.nostrvault.service.translate

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.nostrvault.service.NoteTranslator
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The real engine on a device: libnvtranslate.so loads, fastText names the
 * language, and Mozilla's models download and translate (direct and through
 * English). Needs the network for the first run of each direction.
 */
@RunWith(AndroidJUnit4::class)
class BergamotOnDeviceTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val translator = NoteTranslator(context, TranslationModelStore(context))

    private val spanish = "Hoy hace muy buen tiempo en la ciudad y vamos a ir a la playa con mis amigos."

    @Test
    fun engineLoads() {
        assertTrue(BergamotNative.isAvailable)
        assertTrue("es" in translator.supportedLanguages)
    }

    @Test
    fun identifiesLanguages() = runBlocking {
        assertEquals("es", translator.identify("t-es", spanish))
        assertEquals("de", translator.identify("t-de", "Ich habe heute keine Zeit, weil ich den ganzen Tag arbeiten muss."))
        assertEquals("ja", translator.identify("t-ja", "今日はとても良い天気なので、友達と公園に行きます。"))
    }

    @Test
    fun translatesSpanishToEnglish() = runBlocking {
        val out = translator.translate("t-es-en", spanish, "es", "en")
        android.util.Log.i("BergamotOnDeviceTest", "es->en: $out")
        assertTrue(out, out.contains("beach", ignoreCase = true))
        assertFalse(translator.needsDownload("es", "en"))
    }

    @Test
    fun keepsLinesAndLinks() = runBlocking {
        val note = "Mira esta foto increíble de la playa.\nhttps://example.com/foto.jpg\n#playa"
        val out = translator.translate("t-lines", note, "es", "en")
        android.util.Log.i("BergamotOnDeviceTest", "lines: $out")
        val lines = out.split('\n')
        assertEquals(3, lines.size)
        assertEquals("https://example.com/foto.jpg", lines[1])
        assertEquals("#playa", lines[2])
    }

    @Test
    fun pivotsThroughEnglish() = runBlocking {
        val out = translator.translate("t-es-de", spanish, "es", "de")
        android.util.Log.i("BergamotOnDeviceTest", "es->de: $out")
        assertTrue(out, out.contains("Strand", ignoreCase = true))
    }

    @Test
    fun keepsEmoji() = runBlocking {
        val out = translator.translate("t-emoji", "¡Qué día tan bonito! 🌞🏖️", "es", "en")
        android.util.Log.i("BergamotOnDeviceTest", "emoji: $out")
        assertTrue(out, out.contains("🌞"))
    }
}
