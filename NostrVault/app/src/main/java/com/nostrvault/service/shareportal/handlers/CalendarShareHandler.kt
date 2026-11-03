package com.nostrvault.service.shareportal.handlers

import com.nostrvault.service.shareportal.CalendarShareParser
import com.nostrvault.service.shareportal.CalendarShareTags
import com.nostrvault.service.shareportal.SharePageFetcher
import com.nostrvault.service.shareportal.ShareSigner
import com.nostrvault.shareportal.ShareAction
import com.nostrvault.shareportal.ShareClassifier
import com.nostrvault.shareportal.ShareInput
import com.nostrvault.shareportal.ShareIntent
import java.io.File
import java.time.ZoneId
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Event → calendar (NIP-52, 31922 all-day / 31923 timed), from a shared
 * `.ics` or the page's JSON-LD Event. Published only from the review card.
 * Twin: CalendarShareHandler.swift.
 */
@Singleton
class CalendarShareHandler @Inject constructor(
    private val fetcher: SharePageFetcher,
    private val signer: ShareSigner,
) : ShareHandler {
    override val action = ShareAction.CALENDAR
    override val isReady = true

    /** [icsFile] is the claimed copy of the first `.ics`, if the share had one. */
    suspend fun load(intent: ShareIntent, icsFile: File?): CalendarShareParser.Event {
        icsFile?.takeIf { it.length() in 1..MAX_ICS_BYTES }?.let { file ->
            return CalendarShareParser.ics(file.readText(), ZoneId.systemDefault())
        }
        val url = ShareClassifier.webUrl(ShareInput(url = intent.source.url, text = intent.source.text))
            ?: return CalendarShareParser.Event()
        val html = fetcher.html(url) ?: return CalendarShareParser.Event(url = url)
        val ev = CalendarShareParser.ldEvent(html)
        return if (ev.url.isEmpty()) ev.copy(url = url) else ev
    }

    fun icsFileOf(intent: ShareIntent) = intent.files.firstOrNull {
        it.mime.equals("text/calendar", ignoreCase = true) || it.name.lowercase().endsWith(".ics")
    }

    suspend fun publish(intent: ShareIntent, ev: CalendarShareParser.Event): ShareSigner.Outcome {
        val built = CalendarShareTags.build(ev, UUID.randomUUID().toString())
        return signer.send(intent) { lock ->
            if (ev.allDay) {
                signEventAsync(kind = 31922, content = built.content, tags = built.tags, lockedTo = lock)
            } else {
                signEventAsync(kind = 31923, content = built.content, tags = built.tags, lockedTo = lock)
            }
        }
    }

    companion object {
        const val MAX_ICS_BYTES = 1L * 1024 * 1024
    }
}
