package org.mozufu.pirc.notifications

import android.content.Context
import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mozufu.pirc.MainActivity
import org.mozufu.pirc.call
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class NotificationsChannelTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val signer = TapSigner(context.getSharedPreferences("taps-channel-test", Context.MODE_PRIVATE))
    private val target = OpenTarget.question("s1", "q1", "3", "c1", "Only the failures").json()

    private class System : NotificationSystem {
        var granted = false
        var askable = true
        val asked = mutableListOf<Int>()
        var overlayPages = 0

        override fun permitted() = granted

        override fun canAsk() = askable && !granted

        override fun ask(requestCode: Int) {
            asked += requestCode
        }

        override fun openNotificationSettings() {}

        override fun openOverlaySettings() {
            overlayPages++
        }
    }

    private val system = System()
    private var overlayAllowed = false
    private val overlay = OverlaySwitch(context.getSharedPreferences("overlay-test", Context.MODE_PRIVATE)) { overlayAllowed }

    private fun tap(json: String = target, signature: String? = signer.sign(json)) =
        Intent(context, MainActivity::class.java)
            .setAction(NotificationRenderer.ACTION_OPEN)
            .putExtra(NotificationRenderer.EXTRA_TARGET, json)
            .putExtra(NotificationRenderer.EXTRA_SIGNATURE, signature)

    private fun channel(intent: Intent?, restored: Boolean = false) =
        NotificationsChannel(intent, restored, signer, system, overlay)

    @Test fun theTapThatOpenedTheAppIsGivenOnce() {
        val channel = channel(tap())
        assertEquals("notifications", channel.name)
        assertEquals(target, channel.call("initialOpen").value)
        assertNull(channel.call("initialOpen").value)
    }

    @Test fun onlySignedTapsOfThisAppAreFollowed() {
        assertNull(channel(tap(signature = null)).call("initialOpen").value)
        assertNull(channel(tap(signature = signer.sign("{}"))).call("initialOpen").value)
        assertNull(channel(tap().setAction(Intent.ACTION_MAIN)).call("initialOpen").value)
        assertNull(channel(tap(json = "not json")).call("initialOpen").value)
        // Recents and a restore give the first launch's intent again.
        assertNull(channel(tap(), restored = true).call("initialOpen").value)
        assertNull(channel(tap().addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)).call("initialOpen").value)
    }

    @Test fun aTapWhileTheAppRunsWaitsForDart() {
        val channel = channel(null)
        channel.newIntent(tap())
        // No engine attached: Dart reads it with initialOpen.
        assertEquals(target, channel.call("initialOpen").value)
    }

    @Test fun permissionIsAskedOnlyWhenAsked() {
        val channel = channel(null)
        assertEquals(mapOf("granted" to false, "canAsk" to true), channel.call("permission").value)
        assertTrue(system.asked.isEmpty())
        val answer = channel.call("requestPermission")
        assertFalse(answer.answered)
        assertEquals(listOf(NotificationsChannel.REQUEST_CODE), system.asked)
        system.granted = true
        assertFalse(channel.permissionResult(1))
        assertTrue(channel.permissionResult(NotificationsChannel.REQUEST_CODE))
        assertEquals(mapOf("granted" to true, "canAsk" to false), answer.value)
        // Granted already: nothing is asked again.
        assertEquals(mapOf("granted" to true, "canAsk" to false), channel.call("requestPermission").value)
        assertEquals(1, system.asked.size)
    }

    @Test fun aWaitingPermissionRequestIsAnsweredWhenTheEngineGoes() {
        val channel = channel(null)
        val answer = channel.call("requestPermission")
        assertFalse(answer.answered)
        channel.detach()
        assertTrue(answer.answered)
        assertEquals(mapOf("granted" to false, "canAsk" to true), answer.value)
    }

    @Test fun theOverlaySwitchShowsOffUntilAllowed() {
        val channel = channel(null)
        assertEquals(mapOf("on" to false, "wanted" to false, "allowed" to false), channel.call("overlay").value)
        assertEquals(
            mapOf("on" to false, "wanted" to true, "allowed" to false),
            channel.call("setOverlay", mapOf("on" to true)).value,
        )
        // The system page for "Display over other apps" opened.
        assertEquals(1, system.overlayPages)
        overlayAllowed = true
        assertTrue(overlay.on)
        assertEquals(mapOf("on" to true, "wanted" to true, "allowed" to true), channel.call("overlay").value)
        channel.call("setOverlay", mapOf("on" to false))
        assertFalse(overlay.on)
        assertEquals(1, system.overlayPages)
        assertEquals("INVALID", channel.call("setOverlay", emptyMap()).errorCode)
    }
}
