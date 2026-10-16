package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Port of iOS `BlossomUploadReplyTests`. Replies captured from the real
 * servers on 2026-10-16, uploading a 64x64 PNG with a throwaway key.
 */
class BlossomUploadReplyTest {
    private val sha = "8966a848cbdda8139b451594d1f2111ebdf71927c9ea369ed902c5d9d8e4612b"

    /** `PUT https://nostr.build/upload` and `https://<name>.nostr.build/upload`: 200, the site's home page. */
    @Test
    fun `the nostr build website's home page is not an upload`() {
        val html = "\n\n<!DOCTYPE html>\n<html lang=\"en\">\n\n<head>\n\t<meta charset=\"utf-8\">"
        for (server in listOf("https://nostr.build", "https://test.nostr.build")) {
            assertNull(server, BlossomUploadReply.hostedUrl(html, server, sha, onDeviceRelay = false))
        }
    }

    /** `PUT https://blossom.nostr.build/upload`: the descriptor's link, on the uploader's blossom.band subdomain. */
    @Test
    fun `blossom nostr build's descriptor gives its link`() {
        val link = "https://npub12q2nlqn9pj82y5mw4nx3vw79cv39x7rxtkh5e03y38nfjm9ww8qs4rukn7.blossom.band/$sha.png"
        val body = """{"url":"$link","size":186,"type":"image/png","sha256":"$sha","uploaded":1792141456,"nip94":[["url","$link"],["x","$sha"],["m","image/png"],["dim","64x64"]]}"""
        assertEquals(link, BlossomUploadReply.hostedUrl(body, "https://blossom.nostr.build", sha, onDeviceRelay = false))
    }

    /** khatru (this app's relay, the Mac relay) answers with url + sha256. */
    @Test
    fun `khatru descriptor`() {
        val body = """{"url":"http://192.168.1.20:3355/$sha.png","sha256":"$sha","size":186,"type":"image/png","uploaded":1}"""
        assertEquals("http://192.168.1.20:3355/$sha.png", BlossomUploadReply.hostedUrl(body, "http://192.168.1.20:3355", sha, onDeviceRelay = false))
    }

    @Test
    fun `a descriptor for another blob is not this upload`() {
        val other = "c".repeat(64)
        assertNull(BlossomUploadReply.hostedUrl("""{"url":"https://cdn.example/$other","sha256":"$other"}""", "https://cdn.example", sha, onDeviceRelay = false))
    }

    @Test
    fun `a descriptor without a web link is rejected`() {
        for (url in listOf("", "not a url", "javascript:alert(1)", "file:///etc/passwd")) {
            assertNull(url, BlossomUploadReply.hostedUrl("""{"url":"$url","sha256":"$sha"}""", "https://cdn.example", sha, onDeviceRelay = false))
        }
        assertNull(BlossomUploadReply.hostedUrl("""{"url":5,"sha256":"$sha"}""", "https://cdn.example", sha, onDeviceRelay = false))
    }

    @Test
    fun `an empty reply from an outside server is not an upload`() {
        assertNull(BlossomUploadReply.hostedUrl("", "https://cdn.example", sha, onDeviceRelay = false))
        assertNull(BlossomUploadReply.hostedUrl(null, "https://cdn.example", sha, onDeviceRelay = false))
    }

    @Test
    fun `this device's own relay is addressed by hash`() {
        assertEquals("http://127.0.0.1:3355/$sha", BlossomUploadReply.hostedUrl("", "http://127.0.0.1:3355/", sha, onDeviceRelay = true))
        assertTrue(BlossomUploadReply.isOnDevice("http://127.0.0.1:3355"))
        assertTrue(BlossomUploadReply.isOnDevice("http://localhost:3355"))
        assertFalse(BlossomUploadReply.isOnDevice("http://192.168.1.20:3355"))
        assertFalse(BlossomUploadReply.isOnDevice("https://nostr.build"))
    }
}
