package org.mozufu.pirc

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PlatformChannelsTest {
    private class Feature(override val name: String) : PlatformFeature {
        var detached = false
        var inFront = true

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

    @Test(expected = IllegalArgumentException::class)
    fun twoFeaturesCannotShareAName() {
        PlatformChannels(listOf(Feature("credentials"), Feature("credentials")))
    }
}
