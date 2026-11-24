package dev.pirc.pirc_mobile

import android.Manifest
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import dev.pirc.android.core.*
import dev.pirc.android.push.PushRegistration
import kotlinx.coroutines.launch
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage
import org.unifiedpush.android.connector.FailedReason

object GatewayNotifications {
    const val CHANNEL = "pirc_live"
    private val categories = mapOf("q" to "需要你回應", "missed" to "錯過的排程", "deleg" to "委派的工作", "mem" to "記憶提案", "done" to "完成或失敗", "live" to "即時進度")
    fun intent(context: Context, session: String?, page: String? = null) = Intent(context, MainActivity::class.java)
        .putExtra("gatewaySession", session).putExtra("gatewayRoute", page)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    fun manager(context: Context) = context.getSystemService(NotificationManager::class.java).apply {
        createNotificationChannel(NotificationChannel(CHANNEL, "pirc 工作通知", NotificationManager.IMPORTANCE_DEFAULT))
        for ((id, label) in categories) createNotificationChannel(NotificationChannel("pirc_$id", label,
            if(id=="live") NotificationManager.IMPORTANCE_LOW else NotificationManager.IMPORTANCE_DEFAULT))
    }
    private fun open(context: Context, intent: Intent, key: String) = PendingIntent.getActivity(context, key.hashCode(), intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    fun notification(context: Context, title: String, body: String, session: String?, page: String? = null, category: String = "q"): Notification.Builder {
        manager(context)
        val prefs = NotificationPreferences(context)
        val channel = if(category=="q") CHANNEL else "pirc_$category"
        val public = Notification.Builder(context, channel).setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(if(prefs.lock=="hide") "pirc" else title)
            .setContentText(if(prefs.lock=="all") body else "解鎖後查看內容").build()
        return Notification.Builder(context, channel).setSmallIcon(R.drawable.ic_notification).setContentTitle(title)
            .setContentText(body).setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(open(context,intent(context,session,page),"open:$session:$page"))
            .setVisibility(Notification.VISIBILITY_PRIVATE).setPublicVersion(public).setAutoCancel(true)
    }
    fun show(context: Context, title: String, body: String, session: String?, page: String? = null,
        category: String = "q", workspace: String? = null, question: dev.pirc.android.core.timeline.Interaction? = null, tag: String = session ?: page ?: title) {
        val prefs = context.getSharedPreferences("recent_activity", Context.MODE_PRIVATE)
        val history = runCatching { org.json.JSONArray(prefs.getString("items", "[]")) }.getOrDefault(org.json.JSONArray())
        val next = org.json.JSONArray().put(org.json.JSONObject().put("title", title).put("body", body).put("sessionId", session).put("page", page).put("at", System.currentTimeMillis()))
        for (i in 0 until minOf(history.length(), 99)) next.put(history.get(i))
        prefs.edit().putString("items", next.toString()).apply()
        val settings=NotificationPreferences(context)
        if(!settings.allows(category,workspace)) return
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val notification = notification(context,title,body,session,page,category)
        if(category=="q" && session!=null) {
            val q=question
            val simple=q!=null && q.status=="pending" && !q.multiple && (q.kind=="confirm" || (q.kind=="select" && q.options.size<=3))
            if(settings.enabled("rich") && simple) {
                val options=if(q!!.kind=="confirm") listOf("yes" to "確認…", "no" to "拒絕…") else q.options.map { it.value to it.label }
                for((value,label) in options) {
                    val target=intent(context,session).putExtra("interactionId",q.id).putExtra("answerChoice",value)
                    val action=Notification.Action.Builder(null,label,open(context,target,"$tag:${q.id}:$value"))
                    if(Build.VERSION.SDK_INT>=31) action.setAuthenticationRequired(true)
                    notification.addAction(action.build())
                }
            } else {
                val target=intent(context,session).putExtra("interactionId",q?.id).putExtra("confirmQuestion",true)
                val action=Notification.Action.Builder(null,"開啟對話回答",open(context,target,"answer:$tag"))
                if(Build.VERSION.SDK_INT>=31) action.setAuthenticationRequired(true)
                notification.addAction(action.build())
            }
            if(settings.enabled("popup") && Settings.canDrawOverlays(context)) {
                val reply=PendingIntent.getForegroundService(context,tag.hashCode(),Intent(context,GatewayOverlayService::class.java)
                    .putExtra("sessionId",session).putExtra("interactionId",q?.id),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                val action=Notification.Action.Builder(null,"快速回應…",reply)
                if(Build.VERSION.SDK_INT>=31) action.setAuthenticationRequired(true)
                if(!simple || !settings.enabled("rich") || q!!.options.size<3) notification.addAction(action.build())
            }
            context.getSharedPreferences("question_notifications",Context.MODE_PRIVATE).edit().putString(tag,session).apply()
        }
        if(page?.startsWith("schedule")==true) notification.addAction(Notification.Action.Builder(null,"查看並執行…",open(context,intent(context,null,page),"schedule:$tag")).build())
        if(page?.startsWith("schedule:")==true && settings.enabled("popup") && Settings.canDrawOverlays(context)) {
            val reply=PendingIntent.getForegroundService(context,tag.hashCode(),Intent(context,GatewayOverlayService::class.java).putExtra("scheduleId",page.substringAfter(':')),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val action=Notification.Action.Builder(null,"快速處理…",reply)
            if(Build.VERSION.SDK_INT>=31) action.setAuthenticationRequired(true)
            notification.addAction(action.build())
        }
        manager(context).notify(tag.hashCode(),notification.build())
    }
    private val lastProgress=mutableMapOf<String,Long>()
    fun sync(context: Context, state: dev.pirc.android.core.timeline.SessionState, previous: dev.pirc.android.core.timeline.SessionState? = null) {
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val prefs=NotificationPreferences(context)
        val id=state.session.id
        val pending=state.interactions.any { it.status=="pending" }
        if(prefs.enabled("recall") && !pending) {
            val posted=context.getSharedPreferences("question_notifications",Context.MODE_PRIVATE)
            for((tag,session) in posted.all) if(session==id) { manager(context).cancel(tag.hashCode()); posted.edit().remove(tag).apply() }
        }
        val status=state.run?.status
        val active=status in listOf("running","queued","stopping")
        val progressId=("progress:$id").hashCode()
        if(!active || !prefs.allows("live",state.session.workspaceId)) { manager(context).cancel(progressId); lastProgress.remove(id) }
        else if(System.currentTimeMillis()-(lastProgress[id]?:0)>5000) {
            lastProgress[id]=System.currentTimeMillis()
            val step=state.messages.lastOrNull()?.tools?.lastOrNull()?.title ?: "正在執行工作"
            val note=notification(context,state.session.name,step,id,category="live").setOngoing(true).setOnlyAlertOnce(true).setProgress(0,0,true).setAutoCancel(false)
            manager(context).notify(progressId,note.build())
        }
        if(previous?.run?.id==state.run?.id && previous?.run?.status in listOf("running","queued","stopping","waiting_input") && status in listOf("succeeded","completed","failed","cancelled","stopped"))
            show(context,state.session.name,if(status in listOf("succeeded","completed")) "工作已完成" else "工作已結束：$status",id,category="done",workspace=state.session.workspaceId,tag="done:$id")
    }
}

class GatewayPushService : PushService() {
    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) = PushRegistration.onEndpoint(applicationContext, endpoint)
    override fun onMessage(message: PushMessage, instance: String) {
        if (!message.decrypted) return
        val note = PushNote.parse(message.content) ?: return
        val session = (note.target as? PushTarget.OpenSession)?.sessionId
        val page = when(note.target) { is PushTarget.OpenSchedules -> (note.target as PushTarget.OpenSchedules).scheduleId?.let { "schedule:$it" } ?: "schedules"; PushTarget.OpenMemory -> "memory"; else -> null }
        val category=when { note.tag.startsWith("delegation:") -> "deleg"; page=="memory" -> "mem"; page?.startsWith("schedule")==true -> "missed"; else -> "q" }
        val runtime=GatewayRuntime.get(applicationContext)
        runtime.scope.launch {
            val snapshot=if(session!=null) runCatching { kotlinx.coroutines.withTimeout(8000) { runtime.snapshot(session) } }.getOrNull() else null
            val q=snapshot?.interactions?.firstOrNull { it.status=="pending" }
            GatewayNotifications.show(applicationContext,note.title,note.body,session,page,category,snapshot?.session?.workspaceId,q,note.tag)
        }
    }
    override fun onRegistrationFailed(reason: FailedReason, instance: String) = PushRegistration.fail(applicationContext, reason.toString())
    override fun onUnregistered(instance: String) = PushRegistration.onUnregistered(applicationContext)
}
