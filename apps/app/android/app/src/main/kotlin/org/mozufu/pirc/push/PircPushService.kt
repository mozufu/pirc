package org.mozufu.pirc.push

import android.content.Context
import android.os.PowerManager
import android.util.Log
import java.util.concurrent.Executors
import org.mozufu.pirc.background.BackgroundClient
import org.mozufu.pirc.background.BackgroundConfig
import org.mozufu.pirc.notifications.CompactReads
import org.mozufu.pirc.notifications.NotificationRenderer
import org.mozufu.pirc.notifications.PushNote
import org.mozufu.pirc.notifications.PushReceipt
import org.mozufu.pirc.overlay.OverlayLauncher
import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage

/**
 * The connector's callbacks: endpoints for [PushRegistration], and pushes, which are shown
 * without the Flutter engine. The service is not exported; the connector's own receiver
 * takes the distributor's broadcasts and binds it with `PUSH_EVENT`.
 */
class PircPushService : PushService() {
    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) {
        val keys = endpoint.pubKeySet
        PushRegistration.get(applicationContext).onEndpoint(instance, endpoint.url, keys?.pubKey, keys?.auth)
    }

    override fun onMessage(message: PushMessage, instance: String) {
        // Only messages the connector decrypted with this registration's keys, while
        // that registration and pairing are current.
        if (!message.decrypted) return
        if (!PushRegistration.get(applicationContext).acceptsMessage(instance)) return
        val note = PushNote.parse(message.content) ?: return
        PushDelivery.deliver(applicationContext, note)
    }

    override fun onRegistrationFailed(reason: FailedReason, instance: String) =
        PushRegistration.get(applicationContext).fail(instance, reason.toString())

    override fun onUnregistered(instance: String) = PushRegistration.get(applicationContext).onUnregistered(instance)
}

/**
 * Reads the compact state and shows, updates or removes the notification, off the main
 * thread. A partial wake lock (at most [WAKE_TIMEOUT]) keeps the process running for the
 * read after the connector's binding ends, so a push is not lost to a sleeping phone.
 */
object PushDelivery {
    private val work = Executors.newSingleThreadExecutor()

    /** The background client waits up to 40 s for a call; a push gets this much. */
    private const val WAKE_TIMEOUT = 45_000L

    fun deliver(context: Context, note: PushNote) {
        val app = context.applicationContext
        val wake = app.getSystemService(PowerManager::class.java)
            ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "pirc:push")
            ?.apply {
                setReferenceCounted(false)
                acquire(WAKE_TIMEOUT)
            }
        work.execute {
            try {
                val target = BackgroundConfig.of(app).read() ?: return@execute
                val client = BackgroundClient.create(app, target.gateway, target.clientId)
                val renderer = NotificationRenderer(app)
                val receipt = PushReceipt(reads(client), renderer::shownTags, shownTitle = renderer::shownTitle)
                val steps = receipt.plan(note)
                renderer.apply(steps, target.pairingStamp)
                // Then, beside the notification, the quick-reply overlay when the read showed
                // a question with choices or a missed run. A failure here never touches the
                // notification, which is already posted.
                try {
                    OverlayLauncher.of(app).onReceipt(note, steps)
                } catch (error: RuntimeException) {
                    Log.w("PircPush", "Overlay not opened: ${error.javaClass.simpleName}")
                }
            } catch (error: Exception) {
                // A push is best effort; it must not stop the service.
                Log.w("PircPush", "Could not show a push: ${error.javaClass.simpleName}")
            } finally {
                runCatching { wake?.release() }
            }
        }
    }

    fun reads(client: BackgroundClient) = object : CompactReads {
        override fun interaction(sessionId: String, interactionId: String) = client.interaction(sessionId, interactionId)

        override fun scheduleRun(scheduleId: String, runId: String) = client.scheduleRun(scheduleId, runId)
    }
}
