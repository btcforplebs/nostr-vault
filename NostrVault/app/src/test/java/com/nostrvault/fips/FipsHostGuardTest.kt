package com.nostrvault.fips

import com.nostrvault.di.AppModule
import com.nostrvault.service.MediaCacheService
import com.nostrvault.widget.WidgetImages
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.InetAddress
import java.net.UnknownHostException

/** No media client may hand a `.fips` name to DNS (iOS #992 parity). */
class FipsHostGuardTest {
    private val npub = "npub1xlrwmhu" + "q".repeat(51)

    /** Each real client, with its DNS swapped for one that records every lookup. */
    private fun clients(): Map<String, OkHttpClient> = mapOf(
        "coil" to AppModule.imageHttpClient(),
        "mediaCache" to MediaCacheService.buildHttpClient(),
        "widget" to WidgetImages.client,
    )

    @Test
    fun noClientLooksUpAFipsHost() {
        for ((name, client) in clients()) {
            val looked = mutableListOf<String>()
            val spy = client.newBuilder().dns(object : Dns {
                override fun lookup(hostname: String): List<InetAddress> {
                    looked += hostname
                    throw UnknownHostException(hostname)
                }
            }).build()
            for (url in listOf("http://$npub.fips:3355/abc.jpg", "https://share.FIPS./x.png")) {
                try {
                    spy.newCall(Request.Builder().url(url).build()).execute().close()
                    fail("$name fetched $url")
                } catch (e: FipsHostGuard.Refused) {
                    // refused before any network
                } catch (e: Exception) {
                    fail("$name: $url reached the network (${e.javaClass.simpleName})")
                }
            }
            assertEquals("$name sent a .fips name to DNS", emptyList<String>(), looked)
        }
    }

    @Test
    fun onlyFipsNamesAreRefused() {
        assertTrue(FipsHostGuard.isFipsHost("$npub.fips"))
        assertTrue(FipsHostGuard.isFipsHost("share.FIPS."))
        assertFalse(FipsHostGuard.isFipsHost("fips.example.com"))
        assertFalse(FipsHostGuard.isFipsHost("myfips"))
        assertFalse(FipsHostGuard.isFipsHost("127.0.0.1"))
    }
}
