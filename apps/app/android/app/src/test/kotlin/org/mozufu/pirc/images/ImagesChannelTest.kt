package org.mozufu.pirc.images

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mozufu.pirc.call
import org.mozufu.pirc.direct
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
class ImagesChannelTest {
    /** The start of a static AVIF file: an `ftyp` box with the `avif` brand. */
    private fun avifHeader(brands: String = "avifmif1") =
        byteArrayOf(0, 0, 0, 24) + "ftyp$brands".toByteArray(Charsets.ISO_8859_1) + ByteArray(12)

    @Test fun reportsAvifFromAndroid12() {
        val channel = ImagesChannel(work = direct, reply = direct)
        assertEquals("images", channel.name)
        assertEquals(mapOf("avif" to true), channel.call("imageCapabilities").value)
    }

    @Config(sdk = [30])
    @Test fun reportsNoAvifBeforeAndroid12() {
        val channel = ImagesChannel(work = direct, reply = direct)
        assertEquals(mapOf("avif" to false), channel.call("imageCapabilities").value)
        assertThrows(IllegalArgumentException::class.java) { RasterImages.checkAvif(avifHeader()) }
    }

    @Test fun normalizeAvifReturnsTheConvertedBytes() {
        val png = byteArrayOf(-119, 80, 78, 71)
        var given: ByteArray? = null
        val channel = ImagesChannel(normalize = { given = it; png }, work = direct, reply = direct)
        val answer = channel.call("normalizeAvif", mapOf("bytes" to avifHeader()))
        assertArrayEquals(png, answer.value as ByteArray)
        assertArrayEquals(avifHeader(), given)
    }

    @Test fun badInputIsInvalidAndOtherFailuresAreImages() {
        val channel = ImagesChannel(work = direct, reply = direct)
        assertEquals("INVALID", channel.call("normalizeAvif").errorCode)
        // The checks run before any decoding.
        assertEquals("INVALID", channel.call("normalizeAvif", mapOf("bytes" to ByteArray(4))).errorCode)
        assertEquals("INVALID", channel.call("normalizeAvif", mapOf("bytes" to ByteArray(64))).errorCode)
        assertEquals("INVALID", channel.call("normalizeAvif", mapOf("bytes" to avifHeader("avisavif"))).errorCode)
        val failing = ImagesChannel(normalize = { error("decoder") }, work = direct, reply = direct)
        assertEquals("IMAGES", failing.call("normalizeAvif", mapOf("bytes" to avifHeader())).errorCode)
        assertTrue(channel.call("decode").notImplemented)
    }

    @Test fun theHeaderCheckAcceptsStaticAvif() {
        RasterImages.checkAvif(avifHeader())
        assertThrows(IllegalArgumentException::class.java) {
            RasterImages.checkAvif(ByteArray(RasterImages.MAX_BYTES + 1))
        }
    }
}
