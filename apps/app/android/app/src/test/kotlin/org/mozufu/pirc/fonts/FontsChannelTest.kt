package org.mozufu.pirc.fonts

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mozufu.pirc.call
import org.mozufu.pirc.direct
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
class FontsChannelTest {
    private val collected = mutableListOf<Pair<List<String>, String>>()
    private val fonts = mapOf("resources" to emptyList<Any>(), "matches" to emptyList<Any>())

    private fun channel(supported: Boolean = true) = FontsChannel(
        collect = { families, sample -> collected += families to sample; fonts },
        supported = { supported },
        work = direct,
        reply = direct,
    )

    @Test fun reportsCanvasTextFromAndroid12() {
        assertEquals("fonts", FontsChannel().name)
        assertTrue(CanvasTextFonts.supported())
        assertEquals(mapOf("canvasText" to true), FontsChannel(work = direct, reply = direct).call("fontCapabilities").value)
    }

    @Config(sdk = [30])
    @Test fun refusesBeforeAndroid12() {
        assertFalse(CanvasTextFonts.supported())
        val channel = FontsChannel(work = direct, reply = direct)
        assertEquals(mapOf("canvasText" to false), channel.call("fontCapabilities").value)
        val answer = channel.call("canvasTextFonts", mapOf("families" to listOf("serif"), "sample" to "字"))
        assertEquals("UNSUPPORTED", answer.errorCode)
        assertEquals(
            IllegalStateException::class,
            runCatching { CanvasTextFonts.collect(listOf("serif"), "") }.exceptionOrNull()!!::class,
        )
    }

    @Test fun passesTheFamiliesAndTheSample() {
        val answer = channel().call("canvasTextFonts", mapOf("families" to listOf("serif", "Noto Sans"), "sample" to "中文 abc"))
        assertEquals(fonts, answer.value)
        assertEquals(listOf(listOf("serif", "Noto Sans") to "中文 abc"), collected)
        // Missing arguments mean no families and an empty sample.
        channel().call("canvasTextFonts")
        assertEquals(emptyList<String>() to "", collected.last())
    }

    @Test fun refusesBadRequestsBeforeShaping() {
        val channel = channel()
        val tooMany = List(CanvasTextFonts.MAX_FAMILIES + 1) { "family$it" }
        val tooLong = "a".repeat(CanvasTextFonts.MAX_SAMPLE_LENGTH + 1)
        assertEquals("INVALID", channel.call("canvasTextFonts", mapOf("families" to tooMany)).errorCode)
        assertEquals("INVALID", channel.call("canvasTextFonts", mapOf("families" to listOf("serif"), "sample" to tooLong)).errorCode)
        assertEquals("INVALID", channel.call("canvasTextFonts", mapOf("families" to listOf(" "))).errorCode)
        assertEquals("INVALID", channel.call("canvasTextFonts", mapOf("families" to listOf(1))).errorCode)
        assertTrue(collected.isEmpty())
        assertTrue(channel.call("fonts").notImplemented)
    }

    @Test fun aFailureIsFonts() {
        val failing = FontsChannel(collect = { _, _ -> error("shaper") }, supported = { true }, work = direct, reply = direct)
        val answer = failing.call("canvasTextFonts", mapOf("families" to listOf("serif")))
        assertEquals("FONTS", answer.errorCode)
        assertNull(answer.value)
    }
}
