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

        override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) = result.success(null)

        override fun detach() {
            detached = true
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

    @Test(expected = IllegalArgumentException::class)
    fun twoFeaturesCannotShareAName() {
        PlatformChannels(listOf(Feature("credentials"), Feature("credentials")))
    }
}
