package dev.pirc.pirc_mobile

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel

/** Runtime permissions belong to the live app, independently of demo fixtures. */
class PermissionAccess(private val activity: MainActivity) {
    private val prefs = activity.getSharedPreferences("onboarding", 0)
    private var pending: MethodChannel.Result? = null
    val complete get() = prefs.getInt("version", 0) >= 1
    fun finish() { check(prefs.edit().putInt("version", 1).commit()) { "無法保存引導狀態，請再試一次" } }
    fun status(): Map<String, Any> {
        val manager = activity.getSystemService(NotificationManager::class.java)
        val appEnabled = manager.areNotificationsEnabled()
        val channelEnabled = manager.getNotificationChannel(GatewayNotifications.CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE
        val granted = Build.VERSION.SDK_INT < 33 || activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        val asked = prefs.getBoolean("notificationAsked", false)
        val action = notificationAction(Build.VERSION.SDK_INT, granted, asked,
            Build.VERSION.SDK_INT >= 33 && activity.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS), appEnabled, channelEnabled)
        val settingsRequired = action in listOf(NotificationAction.AppSettings, NotificationAction.ChannelSettings)
        return mapOf("notifications" to (appEnabled && channelEnabled && granted),
            "overlay" to Settings.canDrawOverlays(activity), "notificationSettings" to settingsRequired,
            "onboardingComplete" to complete, "action" to action.name)
    }
    fun notifications(result: MethodChannel.Result) {
        if (pending != null) { result.error("BUSY", "權限視窗已開啟", null); return }
        val state = status()
        if (state["notifications"] == true) { result.success(state); return }
        if (state["action"] == NotificationAction.Request.name) {
            pending = result
            prefs.edit().putBoolean("notificationAsked", true).apply()
            try { activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST) }
            catch (e: Exception) { pending = null; throw e }
        } else {
            val blockedChannel = state["action"] == NotificationAction.ChannelSettings.name
            activity.startActivity(Intent(if (blockedChannel) Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS else Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                .putExtra(Settings.EXTRA_CHANNEL_ID, GatewayNotifications.CHANNEL))
            result.success(status())
        }
    }
    fun overlay() {
        if (!Settings.canDrawOverlays(activity)) activity.startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${activity.packageName}")))
    }
    fun onResult(code: Int) {
        if (code != REQUEST) return
        val result = pending; pending = null
        result?.success(status())
    }
    companion object { const val REQUEST = 8 }
}
