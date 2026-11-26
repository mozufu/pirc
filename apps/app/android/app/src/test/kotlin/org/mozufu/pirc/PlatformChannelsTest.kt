package org.mozufu.pirc

import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlatformChannelsTest {
    private class Feature(override val name: String) : PlatformFeature {
        var detached = false
        var inFront = true
        var channel: MethodChannel? = null

        override fun attached(channel: MethodChannel) {
            this.channel = channel
        }

        override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) = result.success(null)

        override fun detach() {
            detached = true
        }

        override fun background() {
            inFront = false
        }

        override fun foreground() {
            inFront = true
        }

        val results = mutableListOf<Int>()

        override fun activityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
            if (requestCode != name.length) return false
            results += resultCode
            return true
        }
    }

    private class Messenger : BinaryMessenger {
        val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler?>()

        override fun send(channel: String, message: ByteBuffer?) {}

        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}

        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            handlers[channel] = handler
        }
    }

    @Test fun eachFeatureGetsItsOwnChannelAndIsRemovedOnDetach() {
        val features = listOf(Feature("credentials"), Feature("push"))
        val channels = PlatformChannels(features)
        val messenger = Messenger()

        channels.attach(messenger)
        assertEquals(setOf("org.mozufu.pirc/credentials", "org.mozufu.pirc/push"), messenger.handlers.keys)
        assertTrue(messenger.handlers.values.all { it != null })
        assertTrue(features.all { it.channel != null })

        channels.detach()
        assertTrue(messenger.handlers.values.all { it == null })
        assertTrue(features.all { it.detached })
    }

    @Test fun theActivityStateReachesEveryFeature() {
        val features = listOf(Feature("media"), Feature("images"))
        val channels = PlatformChannels(features)
        channels.background()
        assertTrue(features.none { it.inFront })
        channels.foreground()
        assertTrue(features.all { it.inFront })
    }

    @Test fun anActivityResultReachesTheFeatureThatStartedIt() {
        val features = listOf(Feature("media"), Feature("files!"))
        val channels = PlatformChannels(features)
        assertTrue(channels.activityResult(6, -1, null))
        assertEquals(listOf<Int>(), features[0].results)
        assertEquals(listOf(-1), features[1].results)
        assertFalse(channels.activityResult(99, -1, null))
    }

    @Test(expected = IllegalArgumentException::class)
    fun twoFeaturesCannotShareAName() {
        PlatformChannels(listOf(Feature("credentials"), Feature("credentials")))
    }
}
