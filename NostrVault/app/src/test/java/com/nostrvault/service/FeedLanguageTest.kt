package com.nostrvault.service

import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date
import java.util.Locale

/** Port of iOS FeedLanguageTests (MediaLogicTests), plus the Android filter wiring. */
class FeedLanguageTest {

    @Test
    fun `detects common nostr languages`() {
        assertEquals("en", FeedLanguageDetector.detect("Good morning everyone, the price of bitcoin does not matter when you stack every week."))
        assertEquals("es", FeedLanguageDetector.detect("Buenos días a todos, hoy vamos a hablar de cómo funciona la red de nostr."))
        assertEquals("de", FeedLanguageDetector.detect("Guten Morgen zusammen, heute ist ein schöner Tag für einen Spaziergang im Park."))
        assertEquals("ja", FeedLanguageDetector.detect("あなたが遭遇している不運や災難は、実のところ、宇宙があなたに課した試練なのです。"))
        assertEquals("pt", FeedLanguageDetector.detect("Bom dia pessoal, hoje o mercado está calmo e eu vou passear com o meu cachorro."))
    }

    /** Android-only: the script-decided languages, which iOS gets from NLLanguageRecognizer. */
    @Test
    fun `detects languages by their writing system`() {
        assertEquals("zh", FeedLanguageDetector.detect("比特币是一种去中心化的数字货币，不需要银行或者政府的许可。"))
        assertEquals("ko", FeedLanguageDetector.detect("안녕하세요 여러분, 오늘은 정말 좋은 날씨입니다."))
        assertEquals("ru", FeedLanguageDetector.detect("Доброе утро всем, сегодня отличный день для прогулки."))
        assertEquals("uk", FeedLanguageDetector.detect("Доброго ранку всім, сьогодні чудовий день для прогулянки."))
        assertEquals("ar", FeedLanguageDetector.detect("صباح الخير للجميع، اليوم يوم جميل جدا للمشي في الحديقة"))
        assertEquals("fa", FeedLanguageDetector.detect("صبح بخیر به همه، امروز یک روز خوب برای پیاده روی است"))
        assertEquals("th", FeedLanguageDetector.detect("สวัสดีตอนเช้าทุกคน วันนี้อากาศดีมาก"))
        assertEquals("hi", FeedLanguageDetector.detect("सुप्रभात दोस्तों, आज का दिन बहुत अच्छा है"))
    }

    @Test
    fun `detects other latin languages by their function words`() {
        assertEquals("fr", FeedLanguageDetector.detect("Bonjour à tous, aujourd'hui je vais vous parler de la façon dont fonctionne le réseau."))
        assertEquals("it", FeedLanguageDetector.detect("Buongiorno a tutti, oggi il mercato è molto calmo e io vado a fare una passeggiata."))
        assertEquals("nl", FeedLanguageDetector.detect("Goedemorgen allemaal, vandaag is het een mooie dag om naar het park te gaan."))
        assertEquals("vi", FeedLanguageDetector.detect("Chào buổi sáng mọi người, hôm nay là một ngày rất đẹp trời."))
    }

    @Test
    fun `both chinese scripts fold into zh`() {
        assertEquals("zh", FeedLanguageDetector.baseCode("zh-Hans"))
        assertEquals("zh", FeedLanguageDetector.baseCode("zh-Hant"))
        assertEquals("pt", FeedLanguageDetector.baseCode("pt_BR"))
        assertNull(FeedLanguageDetector.baseCode("und"))
        // Java's legacy codes come back as the ISO ones.
        assertEquals("he", FeedLanguageDetector.baseCode("iw-IL"))
        assertEquals("id", FeedLanguageDetector.baseCode("in"))
    }

    /**
     * Short posts and posts that are only links can't be judged, and must not
     * be hidden: that is most image posts.
     */
    @Test
    fun `unjudgeable notes are kept`() {
        assertNull(FeedLanguageDetector.detect("gm"))
        assertNull(FeedLanguageDetector.detect("https://image.nostr.build/abc123def456.jpg #photography #nostr"))
        assertNull(FeedLanguageDetector.detect("nostr:npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq 🔥🔥🔥"))
        assertTrue(FeedLanguageDetector.admits(detected = null, allowed = setOf("en")))
    }

    /**
     * The prose stripper keeps a link-heavy post from reading as English just
     * because URLs are made of English-looking words.
     */
    @Test
    fun `links do not decide the language`() {
        val post = "Guten Morgen zusammen, heute ist ein schöner Tag https://example.com/the-best-english-words-ever #bitcoin"
        assertEquals("de", FeedLanguageDetector.detect(post))
    }

    @Test
    fun admits() {
        assertTrue(FeedLanguageDetector.admits(detected = "es", allowed = emptySet()))
        assertTrue(FeedLanguageDetector.admits(detected = "en", allowed = setOf("en", "es")))
        assertFalse(FeedLanguageDetector.admits(detected = "ja", allowed = setOf("en", "es")))
    }

    @Test
    fun `repost is judged by the reposted text`() {
        val inner = """{"kind":1,"content":"Buenos días a todos, hoy vamos a hablar de cómo funciona la red de nostr.","tags":[]}"""
        val text = FeedLanguageDetector.text(inner, kind = 6)
        assertEquals("es", FeedLanguageDetector.detect(text))
        assertEquals("plain", FeedLanguageDetector.text("plain", kind = 1))
        // Differs from iOS on purpose: FeedNote has already swapped the
        // reposted text in, so a kind-6 note's plain content is that text.
        assertEquals("not json", FeedLanguageDetector.text("not json", kind = 6))
        assertEquals("", FeedLanguageDetector.text("""{"kind":1,"tags":[]}""", kind = 6))
    }

    @Test
    fun `picker lists the device languages first without repeats`() {
        val list = FeedLanguage.pickerList(listOf("de-DE", "en-US", "gsw-CH")).map { it.code }
        assertEquals(listOf("de", "en", "gsw", "es"), list.take(4))
        assertEquals(list.size, list.toSet().size)
        assertEquals(FeedLanguage.OFFERED.size + 1, list.size)
    }

    @Test
    fun `summary names the picked languages`() {
        assertEquals("All languages", FeedLanguage.summary(emptyList(), Locale.ENGLISH))
        assertEquals("German, Japanese", FeedLanguage.summary(listOf("de", "ja"), Locale.ENGLISH))
    }

    // ── FeedFilterEngine: Global's Web of Trust / Everyone and languages ──

    private fun note(id: String, pubkey: String, content: String, kind: Int = 1) =
        FeedNote(id = id, pubkey = pubkey, content = content, createdAt = Date(1_700_000_000_000L), tags = emptyList(), kind = kind)

    private val english = note("en1", "trusted", "Good morning everyone, the price of bitcoin does not matter when you stack every week.")
    private val spanish = note("es1", "trusted", "Buenos días a todos, hoy vamos a hablar de cómo funciona la red de nostr.")
    private val short = note("gm1", "trusted", "gm")
    private val stranger = note("x1", "stranger", "Good morning everyone, the price of bitcoin does not matter when you stack every week.")

    private fun global(
        notes: List<FeedNote>,
        wot: Set<String> = setOf("trusted"),
        requiresTrust: Boolean = true,
        languages: Set<String> = emptySet(),
    ) = FeedFilterEngine.filterFeedNotes(
        notes = notes,
        mode = FeedMode.GLOBAL,
        blocked = emptySet(),
        showReposts = true,
        showReplies = true,
        followedPubkeys = emptySet(),
        wotPubkeys = wot,
        globalLanguages = languages,
        globalRequiresTrust = requiresTrust,
        languageOf = { FeedLanguageDetector.detect(FeedLanguageDetector.text(it.content, it.kind)) },
    ).map { it.id }.toSet()

    @Test
    fun `global web of trust hides strangers and everyone shows them`() {
        assertEquals(setOf("en1"), global(listOf(english, stranger)))
        assertEquals(setOf("en1", "x1"), global(listOf(english, stranger), requiresTrust = false))
    }

    /** iOS parity: an unbuilt graph shows nothing rather than the open firehose. */
    @Test
    fun `global web of trust fails closed on an empty graph`() {
        assertEquals(emptySet<String>(), global(listOf(english, stranger), wot = emptySet()))
        assertEquals(setOf("en1", "x1"), global(listOf(english, stranger), wot = emptySet(), requiresTrust = false))
    }

    @Test
    fun `global language filter keeps picked and unjudgeable notes`() {
        val all = listOf(english, spanish, short)
        assertEquals(setOf("en1", "es1", "gm1"), global(all))
        assertEquals(setOf("en1", "gm1"), global(all, languages = setOf("en")))
        assertEquals(setOf("en1", "es1", "gm1"), global(all, languages = setOf("en", "es")))
        assertEquals(setOf("gm1"), global(all, languages = setOf("ja")))
    }

    @Test
    fun `media global honours everyone`() {
        val photo = note("p1", "stranger", "https://image.nostr.build/abc.jpg")
        fun media(requiresTrust: Boolean) = FeedFilterEngine.filterMediaNotes(
            notes = listOf(photo),
            blocked = emptySet(),
            wotPubkeys = setOf("trusted"),
            isGlobalMedia = true,
            globalRequiresTrust = requiresTrust,
        ).map { it.id }
        assertEquals(emptyList<String>(), media(requiresTrust = true))
        assertEquals(listOf("p1"), media(requiresTrust = false))
    }
}
