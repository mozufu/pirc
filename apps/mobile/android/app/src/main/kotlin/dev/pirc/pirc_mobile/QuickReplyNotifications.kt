package dev.pirc.pirc_mobile

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings

object QuickReplyNotifications {
    const val OVERLAY_ID = 4101
    private const val QUESTION_ID = 4102
    private const val CHANNEL = "mobile_validation_questions"
    private const val SERVICE_CHANNEL = "mobile_validation_overlay"

    fun conversation(context: Context): Intent = Intent(context, MainActivity::class.java)
        .putExtra("sessionId", FixtureStore.SESSION)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)

    private fun open(context: Context) = PendingIntent.getActivity(context, 1, conversation(context),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun manager(context: Context): NotificationManager {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "測試問題", NotificationManager.IMPORTANCE_DEFAULT))
        manager.createNotificationChannel(NotificationChannel(SERVICE_CHANNEL, "快速回應視窗", NotificationManager.IMPORTANCE_LOW))
        return manager
    }

    fun overlay(context: Context): Notification {
        manager(context)
        val close = PendingIntent.getService(context, 3,
            Intent(context, QuickReplyService::class.java).setAction(QuickReplyService.CLOSE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(context, SERVICE_CHANNEL)
            .setSmallIcon(R.drawable.ic_notification).setContentTitle("pirc · 快速回應")
            .setContentText("視窗開啟中；關閉視窗不會回答問題")
            .setContentIntent(open(context)).setOngoing(true).setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(Notification.Action.Builder(null, "關閉視窗", close).build()).build()
    }

    fun showQuestion(context: Context): Boolean {
        val manager = manager(context)
        val state = FixtureStore(context).state()
        if (!manager.areNotificationsEnabled() ||
            manager.getNotificationChannel(CHANNEL).importance == NotificationManager.IMPORTANCE_NONE ||
            (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)) return false
        val builder = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(if (state.status == "handled" || state.status == "expired") "pirc · 問題狀態已更新" else "pirc · 有一個問題待確認")
            .setContentText(when (state.status) {
                "handled" -> "這個測試問題已處理，可開啟對話查看結果"
                "expired" -> "這個測試問題已過期"
                else -> "行動版驗證：這一輪先驗證快速回應浮窗嗎？"
            })
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(open(context)).setAutoCancel(true)
        if (Settings.canDrawOverlays(context) && state.status != "handled" && state.status != "expired") {
            val reply = PendingIntent.getForegroundService(context, 2,
                Intent(context, QuickReplyService::class.java).setAction(QuickReplyService.SHOW),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val action = Notification.Action.Builder(null, "快速回應…", reply)
            if (Build.VERSION.SDK_INT >= 31) action.setAuthenticationRequired(true)
            builder.addAction(action.build())
        }
        builder.addAction(Notification.Action.Builder(null, "開啟對話", open(context)).build())
        manager.notify(QUESTION_ID, builder.build())
        return true
    }

    fun cancelQuestion(context: Context) = manager(context).cancel(QUESTION_ID)
}
