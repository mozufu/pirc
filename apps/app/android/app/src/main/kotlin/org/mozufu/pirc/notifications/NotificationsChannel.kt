package org.mozufu.pirc.notifications

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.mozufu.pirc.PlatformFeature

/**
 * The target of a notification tap in [intent], as JSON, or null. A launch from Recents
 * (`FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`) or a restore ([restored]) carries the first
 * launch's intent again, whose tap was already given; a target this app did not sign
 * (another app can start the exported activity) is ignored.
 */
internal fun openTargetOf(intent: Intent?, restored: Boolean, signer: TapSigner): String? {
    if (intent == null || restored) return null
    if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
    if (intent.action != NotificationRenderer.ACTION_OPEN) return null
    val target = intent.getStringExtra(NotificationRenderer.EXTRA_TARGET) ?: return null
    if (!signer.verify(target, intent.getStringExtra(NotificationRenderer.EXTRA_SIGNATURE))) return null
    return target.takeIf { runCatching { JSONObject(it) }.isSuccess }
}

/** The quick-reply overlay switch (step 4 reads it): on only when wanted and allowed. */
class OverlaySwitch(private val prefs: SharedPreferences, private val isAllowed: () -> Boolean) {
    var wanted: Boolean
        get() = prefs.getBoolean(KEY, false)
        set(value) {
            prefs.edit().putBoolean(KEY, value).commit()
        }

    /** "Display over other apps" is granted. */
    val allowed: Boolean get() = isAllowed()

    val on: Boolean get() = wanted && allowed

    fun toMap() = mapOf("on" to on, "wanted" to wanted, "allowed" to allowed)

    companion object {
        private const val PREFS = "notifications"
        private const val KEY = "quickReplyOverlay"

        fun of(context: Context) = OverlaySwitch(
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE),
        ) { Settings.canDrawOverlays(context.applicationContext) }
    }
}

/** What the channel needs from Android, behind an interface for tests. */
interface NotificationSystem {
    /** Whether notifications may be shown (the Android 13+ permission and the app switch). */
    fun permitted(): Boolean

    /** Whether asking can help: Android 13+ without the permission. */
    fun canAsk(): Boolean

    /** Asks for POST_NOTIFICATIONS; the answer comes to [NotificationsChannel.permissionResult]. */
    fun ask(requestCode: Int)

    fun openNotificationSettings()

    fun openOverlaySettings()
}

private class ActivityNotificationSystem(private val activity: Activity) : NotificationSystem {
    override fun permitted(): Boolean {
        val enabled = activity.getSystemService(NotificationManager::class.java).areNotificationsEnabled()
        return enabled && (Build.VERSION.SDK_INT < 33 || granted())
    }

    override fun canAsk() = Build.VERSION.SDK_INT >= 33 && !granted()

    private fun granted() = Build.VERSION.SDK_INT < 33 ||
        activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    override fun ask(requestCode: Int) {
        if (Build.VERSION.SDK_INT >= 33) {
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), requestCode)
        }
    }

    override fun openNotificationSettings() {
        activity.startActivity(
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName),
        )
    }

    override fun openOverlaySettings() {
        activity.startActivity(
            Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${activity.packageName}")),
        )
    }
}

/**
 * `org.mozufu.pirc/notifications`: notification taps into the app, and the permissions
 * and switches of Settings → Notifications.
 * - `initialOpen` → the JSON target of the tap that opened the app, or one that arrived
 *   while Dart was not listening; given once.
 * - `permission` → `{granted, canAsk}`; `requestPermission` asks (Android 13+) and
 *   answers the same map once the user chose. Only Settings → Notifications asks.
 * - `openSettings` opens the system notification settings of the app.
 * - `overlay` → `{on, wanted, allowed}`; `setOverlay {on}` stores the switch and, when it
 *   is turned on without "Display over other apps", opens that system page. It shows on
 *   only once that permission is granted.
 * - To Dart, `open` with a JSON target when a tap arrives while the app runs, and
 *   `resumed` when the app comes back (permissions may have changed meanwhile).
 */
class NotificationsChannel internal constructor(
    initialIntent: Intent?,
    restored: Boolean,
    private val signer: TapSigner,
    private val system: NotificationSystem,
    private val overlay: OverlaySwitch,
) : PlatformFeature {
    override val name = "notifications"

    private var channel: MethodChannel? = null
    private var pending: String? = openTargetOf(initialIntent, restored, signer)
    private val waiting = mutableListOf<MethodChannel.Result>()

    override fun attached(channel: MethodChannel) {
        this.channel = channel
    }

    override fun detach() {
        channel = null
        // The engine goes; its waiting requests get the state as it is.
        if (waiting.isNotEmpty()) {
            val answer = runCatching { permission() }.getOrDefault(mapOf("granted" to false, "canAsk" to false))
            waiting.forEach { runCatching { it.success(answer) } }
            waiting.clear()
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialOpen" -> {
                val target = pending
                pending = null
                result.success(target)
            }
            "permission" -> result.success(permission())
            "requestPermission" -> {
                if (!system.canAsk()) return result.success(permission())
                waiting += result
                if (waiting.size == 1) system.ask(REQUEST_CODE)
            }
            "openSettings" -> {
                runCatching { system.openNotificationSettings() }
                result.success(null)
            }
            "overlay" -> result.success(overlay.toMap())
            "setOverlay" -> {
                val on = call.argument<Boolean>("on") ?: return result.error("INVALID", "on is required", null)
                overlay.wanted = on
                if (on && !overlay.allowed) runCatching { system.openOverlaySettings() }
                result.success(overlay.toMap())
            }
            else -> result.notImplemented()
        }
    }

    private fun permission() = mapOf("granted" to system.permitted(), "canAsk" to system.canAsk())

    override fun permissionResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val answer = permission()
        waiting.forEach { it.success(answer) }
        waiting.clear()
        return true
    }

    override fun newIntent(intent: Intent) {
        val target = openTargetOf(intent, restored = false, signer) ?: return
        val channel = channel
        if (channel == null) {
            pending = target
            return
        }
        pending = target
        channel.invokeMethod(
            "open",
            target,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (pending == target) pending = null
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}

                override fun notImplemented() {}
            },
        )
    }

    override fun foreground() {
        channel?.invokeMethod("resumed", null)
    }

    companion object {
        const val REQUEST_CODE = 0x7051

        /** [restored]: the activity was created again from saved state. */
        fun create(activity: Activity, restored: Boolean) = NotificationsChannel(
            initialIntent = activity.intent,
            restored = restored,
            signer = TapSigner.of(activity),
            system = ActivityNotificationSystem(activity),
            overlay = OverlaySwitch.of(activity),
        )
    }
}
