package dev.pirc.pirc_mobile

import android.app.*
import android.content.*
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.*
import android.provider.Settings
import android.view.*
import android.widget.*
import dev.pirc.android.core.ApiException
import dev.pirc.android.core.timeline.Interaction
import kotlinx.coroutines.*
import org.json.JSONObject

/** The same verified window lifecycle, backed by real snapshots and control leases. */
class GatewayOverlayService: Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var runtime: GatewayRuntime
    private lateinit var windows: WindowManager
    private var root: ScrollView? = null
    private lateinit var body: LinearLayout
    private lateinit var colors: JSONObject
    private var sessionId = ""
    private var scheduleId: String? = null
    private var missedRun: Map<*, *>? = null
    private var scheduleTitle = "錯過的排程"
    private var questionId: String? = null
    private var question: Interaction? = null
    private var choice: String? = null
    private var sessionTitle = "快速回應"
    private var handled = false
    private var failed = false
    private var expiryJob: Job? = null
    private var status = "確認最新狀態…"
    private var ready = false
    private var busy = false
    private var lockedOutcome = false
    private var pending: Job? = null
    private val screenOff = object: BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) { stopSelf() }
    }
    override fun onCreate() {
        super.onCreate()
        runtime = GatewayRuntime.get(this)
        windows = getSystemService(WindowManager::class.java)
        loadColors()
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(screenOff, IntentFilter(Intent.ACTION_SCREEN_OFF), RECEIVER_NOT_EXPORTED)
        else registerReceiver(screenOff, IntentFilter(Intent.ACTION_SCREEN_OFF))
    }
    private fun loadColors() {
        val appearance = NotificationPreferences(this).read()["appearance"]
        val dark = appearance == "dark" || (appearance != "light" && resources.configuration.uiMode and 0x30 == 0x20)
        colors = JSONObject(assets.open("flutter_assets/assets/design-tokens.json").bufferedReader().use { it.readText() })
            .getJSONObject("color").getJSONObject(if (dark) "dark" else "light")
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (busy && ready.not() && pending?.isActive == true) return START_NOT_STICKY
        loadColors()
        val previousSession = sessionId
        val previousQuestion = questionId
        val previousSchedule=scheduleId
        scheduleId=intent?.getStringExtra("scheduleId")
        if(previousSchedule!=scheduleId) {missedRun=null;choice=null;lockedOutcome=false}
        sessionId=intent?.getStringExtra("sessionId") ?: ""
        if(sessionId.isEmpty() && scheduleId==null) {stopSelf(); return START_NOT_STICKY}
        questionId = intent?.getStringExtra("interactionId")
        if (sessionId != previousSession || questionId != previousQuestion) { question=null; choice=null; lockedOutcome=false }
        try {
            startForeground(4201, GatewayNotifications.notification(this, "pirc · 快速回應", "確認最新問題後才會送出", sessionId).setOngoing(true).build())
            if (!Settings.canDrawOverlays(this) || getSystemService(KeyguardManager::class.java).isKeyguardLocked) {
                GatewayNotifications.show(this, "pirc · 待你處理", "解鎖後開啟對話確認", sessionId)
                stopSelf(); return START_NOT_STICKY
            }
            if (root == null) createWindow()
            refresh()
        } catch (_: Exception) { stopSelf() }
        return START_NOT_STICKY
    }
    private fun dp(n: Int) = (n * resources.displayMetrics.density).toInt()
    private fun color(key: String): Int {
        val raw=colors.getString(key)
        if(!raw.startsWith("rgba")) return Color.parseColor(raw)
        val values=raw.substringAfter('(').substringBefore(')').split(',').map { it.trim().toDouble() }
        return Color.argb((values[3]*255).toInt(),values[0].toInt(),values[1].toInt(),values[2].toInt())
    }
    private fun createWindow() {
        body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(20), dp(16), dp(20), dp(16)) }
        root = object: ScrollView(this) {
            override fun onMeasure(w: Int, h: Int) { super.onMeasure(w, MeasureSpec.makeMeasureSpec((resources.displayMetrics.heightPixels * .7).toInt(), MeasureSpec.AT_MOST)) }
        }.apply {
            addView(body)
            background = GradientDrawable().apply { setColor(color("surface.layer")); cornerRadius = dp(26).toFloat() }
            elevation = dp(12).toFloat()
        }
        windows.addView(root, WindowManager.LayoutParams(minOf(resources.displayMetrics.widthPixels - dp(24), dp(560)), -2,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE, PixelFormat.TRANSLUCENT).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL; y = dp(12)
        })
    }
    private fun text(value: String, size: Float = 15f) { body.addView(TextView(this).apply { text = value; textSize = size; if(size>=17f) typeface=android.graphics.Typeface.create("sans-serif-medium",android.graphics.Typeface.NORMAL); setTextColor(color("text.primary")); setPadding(0, dp(8), 0, dp(8)) }) }
    private fun button(label: String, primary: Boolean = false, enabled: Boolean = true, action: () -> Unit) {
        body.addView(Button(this).apply {
            text = label; isAllCaps = false; stateListAnimator=null; elevation=0f; backgroundTintList=null; minHeight = dp(48); isEnabled = enabled; alpha=if(enabled) 1f else .4f
            setTextColor(color(if(primary) "action.onPrimary" else "text.primary"))
            background = GradientDrawable().apply { setColor(color(if(primary) "action.primary" else "surface.subtle")); cornerRadius = dp(12).toFloat() }
            layoutParams = LinearLayout.LayoutParams(-1,-2).apply { topMargin = dp(8) }
            setOnClickListener { action() }
        })
    }
    private fun option(value: String, label: String) {
        val selected=choice==value
        body.addView(TextView(this).apply {
            text=(if(selected) "◉  " else "○  ")+label; textSize=15f; minHeight=dp(48); gravity=Gravity.CENTER_VERTICAL
            setPadding(dp(14),dp(12),dp(14),dp(12)); setTextColor(color(if(selected) "accent.default" else "text.primary"))
            background=GradientDrawable().apply { setColor(color(if(selected) "accent.soft" else "surface.subtle")); cornerRadius=dp(12).toFloat(); if(selected) setStroke(dp(1),color("accent.default")) }
            layoutParams=LinearLayout.LayoutParams(-1,-2).apply { topMargin=dp(6) }
            isClickable=true; isFocusable=true; contentDescription=label+(if(selected) "，已選取" else "")
            setOnClickListener { choice=value; render() }
        })
    }
    private fun render() {
        if(root==null) return
        root?.background=GradientDrawable().apply { setColor(color("surface.layer")); cornerRadius=dp(26).toFloat() }
        body.removeAllViews()
        val header=LinearLayout(this).apply { gravity=Gravity.CENTER_VERTICAL }
        header.addView(TextView(this).apply { text="π  pirc · $sessionTitle"; textSize=13f; gravity=Gravity.CENTER_VERTICAL; setTextColor(color("text.muted")); maxLines=1; ellipsize=android.text.TextUtils.TruncateAt.END },LinearLayout.LayoutParams(0,dp(48),1f))
        fun icon(label:String,glyph:String,action:()->Unit) { header.addView(TextView(this).apply { text=glyph; textSize=24f; gravity=Gravity.CENTER; contentDescription=label; setTextColor(color("text.secondary")); isClickable=true; isFocusable=true; setOnClickListener { action() } },LinearLayout.LayoutParams(dp(48),dp(48))) }
        icon("開啟完整對話","↗") { startActivity(GatewayNotifications.intent(this,sessionId.takeIf { it.isNotEmpty() },scheduleId?.let { "schedule:$it" })); stopSelf() }
        icon("關閉","×") { stopSelf() }
        body.addView(header)
        text(if(handled) "這項已經處理過了" else if(scheduleId!=null) scheduleTitle else question?.title ?: "確認最新狀態…",20f)
        question?.description?.takeIf { !handled }?.let { text(it,14f) }
        if(busy) body.addView(ProgressBar(this).apply { isIndeterminate=true },LinearLayout.LayoutParams(dp(24),dp(24)).apply { topMargin=dp(12); bottomMargin=dp(12) })
        val q=question
        if(scheduleId!=null && ready && !busy && !lockedOutcome) {
            option("run","執行這次工作"); option("dismiss","略過這次執行")
            button(if(choice=="dismiss") "確認略過" else "確認執行",true,choice!=null) { submitSchedule() }
        }
        if(ready && !busy && !lockedOutcome && q!=null) {
            if(q.kind=="confirm") { option("yes","確認"); option("no","拒絕") }
            else for(o in q.options) option(o.value,o.label)
            button("送出答案",true,choice!=null) { submit() }
            q.expiresAt?.let { text("到期 "+java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date(it)),12f) }
        }
        text(status,13f)
        if(handled) button("好",true) { stopSelf() }
        else if(!busy && !ready) {
            if(failed) button("重試") { refresh() }
            else button("開啟完整對話") { startActivity(GatewayNotifications.intent(this,sessionId.takeIf { it.isNotEmpty() },scheduleId?.let { "schedule:$it" })); stopSelf() }
        }
    }
    private fun refresh() {
        if(scheduleId!=null) { refreshSchedule(); return }
        pending?.cancel(); expiryJob?.cancel(); ready=false; busy=true; handled=false; failed=false; status="確認最新狀態…"; render()
        pending = scope.launch {
            try {
                val state = runtime.snapshot(sessionId)
                sessionTitle=state.session.name
                GatewayNotifications.sync(this@GatewayOverlayService,state)
                val next = if(questionId != null) state.interactions.find { it.id == questionId } else state.interactions.firstOrNull { it.status=="pending" }
                if (question?.id != next?.id || question?.runnerEpoch != next?.runnerEpoch || question?.options != next?.options || question?.title != next?.title) choice=null
                question=next; questionId=next?.id ?: questionId
                when {
                    next == null || next.status != "pending" -> { handled=true; status="最新狀態已確認，不需要再次回答。" }
                    next.runnerEpoch != state.runnerEpoch || (next.expiresAt != null && next.expiresAt!! <= System.currentTimeMillis()) -> status="問題已過期"
                    lockedOutcome -> status="先前送出結果不明，請在完整對話檢查；不會自動重送"
                    next.kind !in listOf("confirm","select") || next.multiple || next.options.size > 3 -> status="請開啟完整對話輸入答案"
                    else -> {
                        val lease = runtime.lease(sessionId, acquire=true)
                        ready=lease["held"]==true
                        status=if(ready) "控制：此裝置" else "控制權在其他裝置，請開啟完整對話確認是否接管"
                        if(ready && next.expiresAt!=null) expiryJob=scope.launch {
                            delay((next.expiresAt!!-System.currentTimeMillis()).coerceAtLeast(1))
                            ready=false; status="問題已過期"; render()
                        }
                    }
                }
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) { failed=true; status="無法確認最新狀態，請重試。" }
            finally { busy=false; render() }
        }
    }
    private val scheduleUnknown get() = getSharedPreferences("uncertain_schedules",MODE_PRIVATE)
    private fun schedulePath() = "/api/schedules/"+android.net.Uri.encode(scheduleId!!)
    private fun refreshSchedule() {
        pending?.cancel();ready=false;busy=true;failed=false;handled=false;status="確認最新狀態…";render()
        pending=scope.launch {
            try {
                val data=runtime.request("GET",schedulePath(),null) as Map<*, *>
                val schedule=data["schedule"] as? Map<*, *>
                scheduleTitle=schedule?.get("title")?.toString() ?: "錯過的排程"
                sessionTitle="排程"
                val runs=(data["runs"] as? List<*>)?.filterIsInstance<Map<*, *>>().orEmpty()
                val next=if(missedRun==null) runs.firstOrNull { it["status"]=="missed" } else runs.firstOrNull { it["id"]==missedRun?.get("id") && it["status"]=="missed" }
                missedRun=next
                lockedOutcome=next!=null && scheduleUnknown.getBoolean("$scheduleId:${next["id"]}",false)
                when {
                    next==null -> {handled=true;status="這次排程已處理，不需要再次操作。"}
                    lockedOutcome -> status="先前送出結果不明，請開啟排程檢查執行紀錄。"
                    else -> {ready=true;status="選擇執行或略過，再按確認。"}
                }
            } catch(e:CancellationException) {throw e}
            catch(e:Exception) {failed=true;status="無法確認最新狀態，請重試。"}
            finally {busy=false;render()}
        }
    }
    private fun submitSchedule() {
        val run=missedRun ?: return
        val action=choice ?: return
        if(!ready || busy || lockedOutcome) return
        ready=false;busy=true;status="送出中…";render()
        pending=scope.launch {
            val key="$scheduleId:${run["id"]}"
            var sent=false
            try {
                val fresh=runtime.request("GET",schedulePath(),null) as Map<*, *>
                val valid=(fresh["runs"] as? List<*>)?.filterIsInstance<Map<*, *>>()?.any { it["id"]==run["id"] && it["status"]=="missed" }==true
                if(!valid) {handled=true;status="這次排程已經處理過了";busy=false;render();return@launch}
                check(scheduleUnknown.edit().putBoolean(key,true).commit())
                sent=true
                runtime.request("POST",schedulePath()+if(action=="run") "/run" else "/runs/${android.net.Uri.encode(run["id"].toString())}/dismiss",if(action=="run") mapOf("runId" to run["id"]) else emptyMap<String,Any>())
                scheduleUnknown.edit().remove(key).commit()
                status=if(action=="run") "已提出執行" else "已略過"; render();delay(1200);stopSelf()
            } catch(e:CancellationException) {throw e}
            catch(e:Exception) {
                lockedOutcome=sent && (e !is ApiException || e.status !in 400..499 || e.code=="outcome_unknown")
                if(!lockedOutcome) scheduleUnknown.edit().remove(key).commit()
                status=if(lockedOutcome) "不確定是否已送達，請開啟排程檢查紀錄；不會重送。" else "狀態已改變或連線失敗，請重新確認。"
                failed=!lockedOutcome;busy=false;render()
            }
        }
    }
    private fun submit() {
        val q=question ?: return; val selected=choice ?: return
        if(busy || !ready || lockedOutcome) return
        busy=true; ready=false; status="送出中…"; render()
        pending=scope.launch {
            try {
                runtime.answer(sessionId,q.id,q.runnerEpoch, if(q.kind=="confirm") mapOf("confirmed" to (selected=="yes")) else mapOf("values" to listOf(selected)))
                status="已送出"; render(); delay(1200); stopSelf()
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                lockedOutcome = e !is ApiException || e.status !in 400..499 || e.code=="outcome_unknown"
                status=if(lockedOutcome) "不確定是否已送達，請檢查狀態" else e.message ?: "問題已變更"
                busy=false; render()
            }
        }
    }
    override fun onConfigurationChanged(config: android.content.res.Configuration) {
        super.onConfigurationChanged(config)
        loadColors();render()
        val view = root ?: return
        val params = view.layoutParams as WindowManager.LayoutParams
        params.width = minOf(resources.displayMetrics.widthPixels - dp(24), dp(560))
        windows.updateViewLayout(view, params)
        view.requestLayout()
    }
    override fun onDestroy() {
        scope.cancel(); root?.let { if(it.isAttachedToWindow) windows.removeView(it) }; root=null
        unregisterReceiver(screenOff); stopForeground(STOP_FOREGROUND_REMOVE); super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
