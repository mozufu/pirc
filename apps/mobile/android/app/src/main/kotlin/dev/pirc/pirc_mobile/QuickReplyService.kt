package dev.pirc.pirc_mobile

import android.app.KeyguardManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject

/** No Flutter Activity/engine is required for the native overlay to stay alive. */
class QuickReplyService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var store: FixtureStore
    private lateinit var windows: WindowManager
    private var window: View? = null
    private var body: LinearLayout? = null
    private var current: ReplyState? = null
    private var choice: String? = null
    private var busy = false
    private var uncertain = false
    private var message: String? = null
    private lateinit var colors: JSONObject
    private val lockReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            QuickReplyNotifications.showQuestion(this@QuickReplyService)
            stopSelf()
        }
    }

    override fun onCreate() {
        super.onCreate()
        store = FixtureStore(this)
        windows = getSystemService(WindowManager::class.java)
        loadColors()
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(lockReceiver, filter, RECEIVER_NOT_EXPORTED)
        else registerReceiver(lockReceiver, filter)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == CLOSE || intent?.action != SHOW) { stopSelf(); return START_NOT_STICKY }
        try {
            startForeground(QuickReplyNotifications.OVERLAY_ID, QuickReplyNotifications.overlay(this))
            if (!Settings.canDrawOverlays(this) || getSystemService(KeyguardManager::class.java).isKeyguardLocked) {
                QuickReplyNotifications.showQuestion(this)
                stopSelf()
                return START_NOT_STICKY
            }
            if (window == null) createWindow()
            refresh()
        } catch (_: RuntimeException) {
            QuickReplyNotifications.showQuestion(this)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun loadColors() {
        val dark = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        colors = JSONObject(assets.open("flutter_assets/assets/design-tokens.json").bufferedReader().use { it.readText() })
            .getJSONObject("color").getJSONObject(if (dark) "dark" else "light")
    }
    private fun color(name: String) = Color.parseColor(colors.getString(name))
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun background(name: String, radius: Int) = GradientDrawable().apply {
        setColor(color(name)); cornerRadius = dp(radius).toFloat()
    }
    private fun windowWidth() = minOf(resources.displayMetrics.widthPixels - dp(24), dp(560))
    private fun createWindow() {
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(16), dp(20), dp(20))
            background = background("surface.layer", 28)
        }
        body = content
        val scroll = object : ScrollView(this) {
            override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                val maxHeight = (resources.displayMetrics.heightPixels * .68).toInt()
                super.onMeasure(widthMeasureSpec, MeasureSpec.makeMeasureSpec(maxHeight, MeasureSpec.AT_MOST))
            }
        }.apply {
            addView(content)
            elevation = dp(12).toFloat()
            clipToOutline = true
            background = background("surface.layer", 28)
        }
        val params = WindowManager.LayoutParams(windowWidth(), WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE, PixelFormat.TRANSLUCENT).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            y = dp(12)
        }
        windows.addView(scroll, params)
        window = scroll
    }

    private fun text(value: String, size: Float = 15f, bold: Boolean = false) = TextView(this).apply {
        text = value
        textSize = size
        setTextColor(color("text.primary"))
        setPadding(0, dp(6), 0, dp(6))
        setLineSpacing(dp(3).toFloat(), 1f)
        if (bold) setTypeface(typeface, Typeface.BOLD)
    }
    private fun button(label: String, primary: Boolean = false, enabled: Boolean = true, action: () -> Unit) = Button(this).apply {
        text = label; isAllCaps = false; minHeight = dp(48)
        minimumHeight = dp(48)
        setTextColor(color(if (primary) "action.onPrimary" else "text.primary"))
        background = background(if (primary) "action.primary" else "surface.subtle", 12)
        isEnabled = enabled
        alpha = if (enabled) 1f else .45f
        setOnClickListener { action() }
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) }
    }

    private fun render() {
        val content = body ?: return
        content.removeAllViews()
        content.addView(text("pirc · 快速回應", 18f, true))
        content.addView(text("本機測試 · 行動版設計", 12f))
        content.addView(text("這一輪先驗證快速回應浮窗嗎？", 18f))
        val state = current
        val status = when {
            busy -> "確認最新狀態…"
            uncertain -> "不確定是否已送達，請檢查狀態"
            state?.status == "handled" -> "已回覆：${state.answer}\n${state.actor.orEmpty()}\n${state.answeredAt.orEmpty()}"
            state?.status == "expired" -> "這個問題已過期，無法回答"
            state?.status == "controlledElsewhere" -> "由另一台裝置控制中；請在完整客戶端處理控制權"
            state?.status == "offline" -> "無法確認最新狀態，請檢查連線"
            else -> "請選擇後按送出"
        }
        content.addView(text(status))
        message?.let { content.addView(text(it)) }
        if (!busy && !uncertain && state?.status == "pending") {
            for (option in ReplyRules.choices) {
                content.addView(button((if (choice == option) "✓ " else "") + option) { choice = option; render() })
            }
            content.addView(button("送出答案", primary = true, enabled = choice != null && message == null) { submit() })
            content.addView(text("控制：此裝置（測試資料）", 12f))
        }
        if (!busy && state?.status != "handled" && state?.status != "expired") {
            content.addView(button(if (uncertain) "檢查狀態" else "重新整理") { refresh() })
        }
        content.addView(button("開啟完整對話") {
            try {
                startActivity(QuickReplyNotifications.conversation(this))
                stopSelf()
            } catch (_: RuntimeException) {
                message = "無法開啟對話，請從 pirc App 進入"
                render()
            }
        })
        content.addView(button(if (state?.status == "handled") "好" else "關閉視窗") { stopSelf() })
    }

    private fun refresh() {
        if (busy) return
        busy = true; message = null; render()
        handler.postDelayed({
            val latest = store.state()
            if (current?.revision != latest.revision) choice = null
            current = latest
            if (latest.status == "handled" || latest.status == "expired") uncertain = false
            busy = false
            render()
        }, 600)
    }

    private fun submit() {
        val selected = choice ?: return
        val confirmed = current ?: return
        if (busy || uncertain || confirmed.status != "pending" || message != null) return
        busy = true; render()
        handler.postDelayed({
            val latest = store.state()
            if (latest.status != "pending" || latest.revision != confirmed.revision) {
                current = latest; choice = null; busy = false
                message = if (latest.status == "pending") "問題已更新，請重新確認" else null
                render()
                return@postDelayed
            }
            try {
                store.answer(confirmed.revision, selected)
                current = store.state()
                QuickReplyNotifications.cancelQuestion(this)
                message = "已送出，即將關閉"
                handler.postDelayed({ stopSelf() }, 1500)
            } catch (e: FixtureFailure) {
                uncertain = e.code != "REJECTED"
                if (!uncertain) { current = store.state(); message = "狀態已變更，未送出你的答案" }
            } catch (_: Exception) {
                uncertain = true
            }
            busy = false
            render()
        }, 600)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        loadColors()
        window?.let { view ->
            val params = view.layoutParams as WindowManager.LayoutParams
            params.width = windowWidth()
            windows.updateViewLayout(view, params)
            body?.background = background("surface.layer", 28)
        }
        render()
    }
    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        window?.let { if (it.isAttachedToWindow) windows.removeView(it) }
        window = null; body = null
        unregisterReceiver(lockReceiver)
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
    companion object {
        const val SHOW = "dev.pirc.mobile.SHOW"
        const val CLOSE = "dev.pirc.mobile.CLOSE"
    }
}
