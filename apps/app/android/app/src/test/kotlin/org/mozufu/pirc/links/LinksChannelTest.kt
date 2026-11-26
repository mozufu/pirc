package org.mozufu.pirc.links

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mozufu.pirc.call
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class LinksChannelTest {
    private val link = "pirc://pair?url=https%3A%2F%2Fgateway.test&token=pirc_dev_abc"

    /** Records what Kotlin sends to Dart and answers each call with [reply]. */
    private class Messenger(var reply: (() -> ByteBuffer?)? = null) : BinaryMessenger {
        val sent = mutableListOf<Pair<String, Any?>>()

        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)

        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            val bytes = message!!.apply { if (position() > 0) flip() }
            val call = StandardMethodCodec.INSTANCE.decodeMethodCall(bytes)
            sent += call.method to call.arguments
            callback?.reply(reply?.invoke())
        }

        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
    }

    private fun success(): ByteBuffer = StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(null).apply { flip() }

    private fun intent(data: String?) = Intent(Intent.ACTION_VIEW).apply { data?.let { setData(Uri.parse(it)) } }

    @Test fun onlyPairLinksAreAccepted() {
        assertEquals(link, pairLinkOf(link))
        assertEquals("PIRC://pair?url=x", pairLinkOf("PIRC://pair?url=x"))
        assertNull(pairLinkOf(null))
        assertNull(pairLinkOf(""))
        assertNull(pairLinkOf("pirc://other?url=x"))
        assertNull(pairLinkOf("https://pair?url=x"))
        assertNull(pairLinkOf("pirc:pair"))
        assertNull(pairLinkOf("pirc://pair?" + "a".repeat(5000)))
        assertNull(pairLinkOf("pirc://pa ir"))
    }

    @Test fun theLaunchLinkIsGivenOnce() {
        var consumed = 0
        val channel = LinksChannel(initialIntentData = link, openUrl = {}, consumed = { consumed++ })
        assertEquals("links", channel.name)
        assertEquals(link, channel.call("initialLink").value)
        assertEquals(1, consumed)
        assertNull(channel.call("initialLink").value)
        assertEquals(1, consumed)
        // A launch without a pairing link has none.
        assertNull(LinksChannel(initialIntentData = "https://example.test/", openUrl = {}).call("initialLink").value)
    }

    @Test fun anOldLaunchIntentGivesNoLink() {
        assertEquals(link, launchLinkOf(intent(link), restored = false))
        // From Recents, or restored from saved state: the link was already given.
        val fromHistory = intent(link).addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)
        assertNull(launchLinkOf(fromHistory, restored = false))
        assertNull(launchLinkOf(intent(link), restored = true))
        assertNull(launchLinkOf(null, restored = false))
        assertNull(launchLinkOf(intent("https://example.test/"), restored = false))
        val channel = LinksChannel(initialIntentData = null, openUrl = {})
        channel.newIntent(fromHistory)
        assertNull(channel.call("initialLink").value)
    }

    @Test fun aLinkWhileRunningIsSentToDart() {
        val messenger = Messenger { success() }
        var consumed = 0
        val channel = LinksChannel(initialIntentData = null, openUrl = {}, consumed = { consumed++ })
        channel.attached(MethodChannel(messenger, "org.mozufu.pirc/links"))
        channel.newIntent(intent(link))
        channel.newIntent(intent("https://example.test/"))
        channel.newIntent(intent(null))
        assertEquals(listOf("link" to link), messenger.sent)
        // Dart took it, so it is not given again.
        assertEquals(1, consumed)
        assertNull(channel.call("initialLink").value)
    }

    @Test fun aLinkDartDidNotTakeWaitsForInitialLink() {
        // No handler on the Dart side yet: the engine answers with an empty reply.
        val messenger = Messenger { null }
        var consumed = 0
        val channel = LinksChannel(initialIntentData = null, openUrl = {}, consumed = { consumed++ })
        channel.attached(MethodChannel(messenger, "org.mozufu.pirc/links"))
        channel.newIntent(intent(link))
        assertEquals(0, consumed)
        assertEquals(link, channel.call("initialLink").value)
        assertEquals(1, consumed)

        // Before attach, the link waits too.
        val early = LinksChannel(initialIntentData = null, openUrl = {})
        early.newIntent(intent(link))
        assertEquals(link, early.call("initialLink").value)
    }

    @Test fun onlyWebAddressesOpenInTheBrowser() {
        val opened = mutableListOf<String>()
        val channel = LinksChannel(initialIntentData = null, openUrl = { opened += it })
        assertNull(channel.call("openBrowser", mapOf("url" to "https://gateway.test/?pair=p1")).errorCode)
        assertEquals("INVALID", channel.call("openBrowser", mapOf("url" to "javascript:alert(1)")).errorCode)
        assertEquals("INVALID", channel.call("openBrowser", mapOf("url" to "file:///sdcard/x")).errorCode)
        assertEquals("INVALID", channel.call("openBrowser", mapOf("url" to "https:///nohost")).errorCode)
        assertEquals("INVALID", channel.call("openBrowser").errorCode)
        assertEquals(listOf("https://gateway.test/?pair=p1"), opened)

        val none = LinksChannel(initialIntentData = null, openUrl = { throw ActivityNotFoundException() })
        assertEquals("NO_BROWSER", none.call("openBrowser", mapOf("url" to "http://gateway.test/")).errorCode)
        assertTrue(channel.call("other").notImplemented)
    }
}
