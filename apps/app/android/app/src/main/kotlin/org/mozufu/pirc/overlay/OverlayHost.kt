package org.mozufu.pirc.overlay

import android.app.KeyguardManager
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ComponentCallbacks
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.view.Display
import android.view.Gravity
import android.view.WindowManager
import java.util.concurrent.Executor
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import org.mozufu.pirc.background.BackgroundClient
import org.mozufu.pirc.background.BackgroundConfig
import org.mozufu.pirc.notifications.ActionLabel
import org.mozufu.pirc.notifications.NotificationRenderer
import org.mozufu.pirc.notifications.OpenTarget
import org.mozufu.pirc.notifications.OverlaySwitch
import org.mozufu.pirc.notifications.PushKind
import org.mozufu.pirc.notifications.PushNote
import org.mozufu.pirc.notifications.ReceiptStep
import org.mozufu.pirc.notifications.TapSigner

/**
 * Whether a push opens the quick-reply overlay. It opens only:
 * - for an agent question or a missed run (default E), and only when push receipt's own
 *   compact read showed it open: the question with its choices, the run as missed. A run
 *   that failed or finished has the same push target and gets no overlay; neither does
 *   a push whose state could not be read;
 * - while the overlay switch is on with "Display over other apps" granted
 *   ([OverlaySwitch.on]) and the screen is on and not locked;
 * - for a push that is not a quiet-hours one (`silent`): a window that pops up would be
 *   louder than the silent notification the user chose.
 *
 * The notification is posted in every case, the overlay comes in addition: closing the
 * overlay leaves the item in "Needs you" with its notification.
 */
object OverlayGate {
    fun itemFor(note: PushNote, steps: List<ReceiptStep>, switchOn: Boolean, unlocked: Boolean): OverlayItem? {
        if (!switchOn || !unlocked || note.silent) return null
        val shown = steps.filterIsInstance<ReceiptStep.Show>().firstOrNull { it.spec.tag == note.tag }?.spec ?: return null
        return when (val kind = note.kind) {
            is PushKind.Question -> if (shown.choices.isEmpty()) {
                null
            } else {
                OverlayItem.Question(kind.sessionId, kind.interactionId, kind.epoch, note.tag)
            }
            is PushKind.Run -> if (shown.actions.none { it.label == ActionLabel.VIEW_AND_RUN }) {
                null
            } else {
                OverlayItem.Run(kind.scheduleId, kind.runId, note.tag)
            }
            else -> null
        }
    }

    /** The screen is on and not locked (`isKeyguardLocked`, as the old app checks). */
    fun unlocked(context: Context): Boolean {
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        val power = context.getSystemService(PowerManager::class.java)
        return keyguard?.isKeyguardLocked == false && power?.isInteractive == true
    }
}

/** Where the launcher shows an item; [OverlayHost] in the app. */
interface OverlayDisplay {
    /** The item on screen, or null. */
    val shown: OverlayItem?

    fun show(item: OverlayItem)

    fun recheck(item: OverlayItem)
}

/**
 * Opens the overlay for a push after push receipt applied its steps (the notification is
 * already posted). [onReceipt] is called for every push.
 */
class OverlayLauncher(
    private val display: OverlayDisplay,
    private val switchOn: () -> Boolean,
    private val unlocked: () -> Boolean,
) {
    /** True when the overlay was asked to show [note]'s item. */
    fun onReceipt(note: PushNote, steps: List<ReceiptStep>): Boolean {
        recheckIfShown(note)
        val item = OverlayGate.itemFor(note, steps, switchOn(), unlocked()) ?: return false
        display.show(item)
        return true
    }

    /** A push about the question on screen (answered, or the session changed): read it again. */
    private fun recheckIfShown(note: PushNote) {
        val shown = display.shown as? OverlayItem.Question ?: return
        val about = when (val kind = note.kind) {
            is PushKind.Answered -> kind.sessionId == shown.sessionId && kind.interactionId == shown.interactionId
            is PushKind.Refresh -> kind.sessionId == shown.sessionId
            else -> false
        }
        if (about) display.recheck(shown)
    }

    companion object {
        fun of(context: Context): OverlayLauncher {
            val app = context.applicationContext
            val switch = OverlaySwitch.of(app)
            return OverlayLauncher(OverlayHost.get(app), { switch.on }) { OverlayGate.unlocked(app) }
        }
    }
}

/**
 * The quick-reply overlay (C § 6.4): a `TYPE_APPLICATION_OVERLAY` bottom sheet above
 * other apps, drawn by [OverlayView] from the state of an [OverlayController]. One host
 * per process; the window and the controller live on the main thread.
 *
 * The window is added first, from a window context of the application: Android refuses
 * to start a service from the background even with "Display over other apps" granted
 * (`BackgroundServiceStartNotAllowedException`, seen on Android 16), and a push arrives
 * in the background. Once the window is on screen the app counts as visible, and
 * [OverlayService] is started as the window's anchor; when it stops, the window goes.
 *
 * The window is exactly the sheet and never focusable (no text field needs a keyboard),
 * so touches outside it go to the app below and leave the overlay open, and the back key
 * goes to that app too; the × and "Later" close it. It closes by itself [IDLE_TIMEOUT]
 * after the last touch (not while a send is out), when the screen goes off, and after a
 * send. However it closes, the window is removed and nothing is answered: the item keeps
 * its notification and stays in "Needs you". A push for another item while a send is out
 * does not replace the overlay; that item has its notification.
 */
class OverlayHost internal constructor(
    private val app: Context,
    /** Starts the anchor service; tests leave it out. */
    private val anchor: Boolean = true,
) : OverlayDisplay, OverlayEffects, OverlayActions {
    private val handler = Handler(Looper.getMainLooper())
    private val main = Executor { handler.post(it) }

    /** A window context on API 30+, whose WindowManager adds the window to its display. */
    private val ui: Context by lazy {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            runCatching {
                val display = app.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
                app.createDisplayContext(display).createWindowContext(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, null)
            }.getOrElse { app }
        } else {
            app
        }
    }
    private val windows: WindowManager? get() = ui.getSystemService(WindowManager::class.java)
    private var view: OverlayView? = null
    private var added = false
    private var controller: OverlayController? = null
    private var listening = false

    /** The signed intent of the top right for the item on screen, made off the main thread. */
    private var openIntent: Intent? = null

    /** Names the anchor started for the window on screen; a close moves it on. */
    private var anchorToken = 0L

    @Volatile
    override var shown: OverlayItem? = null
        private set

    private val idle = Runnable { onIdle() }

    /** Once a minute, so "Expires in N min" stays true; only that line changes. */
    private val tick = object : Runnable {
        override fun run() {
            controller?.let { view?.refreshExpiry(it.state) }
            handler.postDelayed(this, TICK)
        }
    }

    private val screenOff = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = close()
    }

    private val configuration = object : ComponentCallbacks {
        override fun onConfigurationChanged(newConfig: Configuration) = redraw()

        @Deprecated("Deprecated in Java")
        override fun onLowMemory() = Unit
    }

    /** What a controller needs, read off the main thread (preferences, Keystore client, signer). */
    private class Prepared(
        val item: OverlayItem,
        val clientId: String,
        val gateway: OverlayGateway,
        val uncertain: UncertainSends,
        val io: Executor,
        val sentCloseMillis: Long,
        val open: Intent,
    )

    /** Any thread. */
    override fun show(item: OverlayItem) {
        val io = overrides?.io ?: IO
        io.execute {
            val prepared = try {
                prepare(item)
            } catch (error: RuntimeException) {
                Log.w(TAG, "Overlay not prepared: ${error.javaClass.simpleName}")
                null
            } ?: return@execute
            handler.post { showNow(prepared) }
        }
    }

    /** Any thread. */
    override fun recheck(item: OverlayItem) {
        handler.post { if (controller?.item == item) controller?.recheck() }
    }

    private fun prepare(item: OverlayItem): Prepared? {
        val open = NotificationRenderer.openIntent(app, TapSigner.of(app), item.open)
        overrides?.let { debug ->
            val uncertain = debug.uncertain ?: UncertainSends.of(app)
            return Prepared(item, debug.clientId, debug.gateway, uncertain, debug.io ?: IO, debug.sentCloseMillis, open)
        }
        val target = BackgroundConfig.of(app).read() ?: return null
        val uncertain = UncertainSends.of(app).also { it.prune() }
        val client = BackgroundClient.create(app, target.gateway, target.clientId)
        return Prepared(item, target.clientId, OverlayGateway.of(client), uncertain, IO, OverlayController.SENT_CLOSE_MILLIS, open)
    }

    private fun showNow(prepared: Prepared) {
        val item = prepared.item
        // Checked again here: the permission or the lock may have changed meanwhile.
        if (!Settings.canDrawOverlays(app) || !OverlayGate.unlocked(app)) return
        val current = controller
        if (current?.item == item) {
            current.recheck()
            resetIdle()
            return
        }
        if (current != null && current.sending) {
            // A send is out: the overlay stays; the new item has its notification.
            Log.i(TAG, "Overlay busy sending; the new item keeps its notification only")
            return
        }
        current?.dispose()
        controller = null
        val later: (Long, Runnable) -> () -> Unit = { delay, task ->
            handler.postDelayed(task, delay)
            ({ handler.removeCallbacks(task) })
        }
        val next = OverlayController(
            item, prepared.clientId, prepared.gateway, prepared.uncertain, this, prepared.io, main, later,
            sentCloseMillis = prepared.sentCloseMillis,
        )
        if (!ensureWindow()) {
            next.dispose()
            return close()
        }
        controller = next
        openIntent = prepared.open
        shown = item
        next.check()
        resetIdle()
    }

    private fun ensureWindow(): Boolean {
        if (view != null) return true
        val created = OverlayView(viewContext(), this)
        created.onTouch = { resetIdle() }
        try {
            windows?.addView(created.root, layoutParams()) ?: return false
        } catch (error: RuntimeException) {
            // BadTokenException or a missing permission: the notification remains.
            Log.w(TAG, "Overlay window refused: ${error.javaClass.simpleName}")
            return false
        }
        view = created
        added = true
        if (!listening) {
            app.registerReceiver(screenOff, IntentFilter(Intent.ACTION_SCREEN_OFF), Context.RECEIVER_NOT_EXPORTED)
            app.registerComponentCallbacks(configuration)
            listening = true
        }
        handler.removeCallbacks(tick)
        handler.postDelayed(tick, TICK)
        // The anchor starts once the window is on screen: only a visible overlay makes
        // this app a foreground one ("has-overlay-ui") that may start a service, and
        // Android takes a moment to see it.
        if (anchor) handler.postDelayed({ startAnchor(created) }, ANCHOR_DELAY)
        return true
    }

    private fun startAnchor(shownView: OverlayView) {
        if (view !== shownView) return
        OverlayService.owner = this
        try {
            app.startService(Intent(app, OverlayService::class.java).putExtra(OverlayService.EXTRA_TOKEN, ++anchorToken))
        } catch (error: RuntimeException) {
            // The window stays without its anchor; it closes in the same ways.
            Log.w(TAG, "Overlay anchor not started: ${error.javaClass.simpleName}")
        }
    }

    private fun layoutParams() = WindowManager.LayoutParams(
        width(),
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
        // The margin below the sheet is outside the window, so it takes no touches.
        y = (MARGIN_DP * app.resources.displayMetrics.density).toInt()
        title = "pirc quick reply"
    }

    /** The screen's width less a margin on each side, at most [MAX_WIDTH_DP]. */
    private fun width(): Int {
        val metrics = app.resources.displayMetrics
        return minOf(metrics.widthPixels - (2 * MARGIN_DP * metrics.density).toInt(), (MAX_WIDTH_DP * metrics.density).toInt())
    }

    /**
     * The views take the window context with the application's configuration: a display
     * context alone would drop the language chosen for this app (zh-TW).
     */
    private fun viewContext(): Context = if (ui === app) app else ui.createConfigurationContext(app.resources.configuration)

    /** Dark mode, rotation, density or the language changed: draw again with the new configuration. */
    private fun redraw() {
        val shownView = view ?: return
        shownView.updateContext(viewContext())
        controller?.let { shownView.render(it.state, OverlayView.isDark(app)) }
        runCatching {
            val params = shownView.root.layoutParams as WindowManager.LayoutParams
            params.width = width()
            windows?.updateViewLayout(shownView.root, params)
        }
    }

    private fun resetIdle() {
        handler.removeCallbacks(idle)
        handler.postDelayed(idle, IDLE_TIMEOUT)
    }

    private fun onIdle() {
        if (controller?.sending == true) resetIdle() else close()
    }

    /** The receivers and callbacks are registered (tests check they go). */
    internal val isListening get() = listening

    // ---- OverlayEffects -------------------------------------------------------------

    override fun render(state: OverlayState) {
        view?.render(state, OverlayView.isDark(app))
        overrides?.afterRender?.let { hook -> controller?.let { hook(it, state) } }
    }

    /** Removes the window and everything it registered. Main thread; safe to call twice. */
    override fun close() {
        shown = null
        controller?.dispose()
        controller = null
        openIntent = null
        handler.removeCallbacks(idle)
        handler.removeCallbacks(tick)
        val hadView = view != null
        view?.let { shownView ->
            if (added) runCatching { windows?.removeViewImmediate(shownView.root) }
        }
        added = false
        view = null
        if (listening) {
            runCatching { app.unregisterReceiver(screenOff) }
            app.unregisterComponentCallbacks(configuration)
            listening = false
        }
        anchorToken++
        if (anchor && hadView) runCatching { app.stopService(Intent(app, OverlayService::class.java)) }
    }

    /**
     * The anchor started with [token] stopped. When Android stopped it while its window
     * is still on screen, the window goes too; a stop that comes after the window closed
     * (and perhaps a new one opened) does nothing. Main thread.
     */
    internal fun anchorStopped(token: Long) {
        if (token == anchorToken && view != null) close()
    }

    override fun removeNotification(tag: String) {
        runCatching { app.getSystemService(NotificationManager::class.java)?.cancel(tag, NotificationRenderer.ID) }
    }

    override fun open(target: OpenTarget) {
        // Started while the overlay is still on screen: that is what lets this app start
        // an activity from the background. The intent was signed when the item came.
        val intent = openIntent?.takeIf { controller?.item?.open == target }
            ?: NotificationRenderer.openIntent(app, TapSigner.of(app), target)
        runCatching { app.startActivity(intent) }
            .onFailure { Log.w(TAG, "Could not open the app: ${it.javaClass.simpleName}") }
        close()
    }

    // ---- OverlayActions -------------------------------------------------------------

    override fun select(choiceId: String) {
        controller?.select(choiceId)
    }

    override fun send() {
        controller?.send()
    }

    override fun decide(action: RunAction) {
        controller?.decide(action)
    }

    override fun retry() {
        controller?.check()
    }

    override fun open() {
        controller?.openConversation()
    }

    /** Test and debug data in place of the Gateway (debug builds set it; release never does). */
    internal class Overrides(
        val gateway: OverlayGateway,
        val clientId: String,
        val uncertain: UncertainSends? = null,
        val io: Executor? = null,
        val sentCloseMillis: Long = OverlayController.SENT_CLOSE_MILLIS,
        val afterRender: ((OverlayController, OverlayState) -> Unit)? = null,
    )

    companion object {
        private const val TAG = "PircOverlay"
        const val IDLE_TIMEOUT = 120_000L
        private const val ANCHOR_DELAY = 1_000L
        private const val TICK = 60_000L
        private const val MAX_WIDTH_DP = 560
        private const val MARGIN_DP = 10

        /**
         * The overlay's requests: up to 4 threads, made when needed, so one hung request
         * does not hold up the others. A thread outlives a window, so a send that is out
         * when the overlay closes still records its outcome.
         */
        private val IO: Executor = ThreadPoolExecutor(4, 4, 30, TimeUnit.SECONDS, LinkedBlockingQueue()) { task ->
            Thread(task, "pirc-overlay").apply { isDaemon = true }
        }.apply {
            // Idle threads end; a fifth request waits in the queue, never on the caller's
            // (main) thread.
            allowCoreThreadTimeOut(true)
        }

        @Volatile
        internal var overrides: Overrides? = null

        @Volatile
        private var instance: OverlayHost? = null

        fun get(context: Context): OverlayHost = instance ?: synchronized(this) {
            instance ?: OverlayHost(context.applicationContext).also { instance = it }
        }
    }
}

/**
 * The anchor of the overlay window: a started service that runs while the window is on
 * screen. [OverlayHost] starts it once the window is drawn and stops it on close; when
 * Android stops it, the window it was started for is removed. Each start carries a
 * token, so a late stop never removes a newer window.
 */
class OverlayService : Service() {
    private var token = -1L

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        token = intent?.getLongExtra(EXTRA_TOKEN, -1L) ?: -1L
        if (owner?.shown == null) stopSelf()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        owner?.anchorStopped(token)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val EXTRA_TOKEN = "org.mozufu.pirc.overlay.token"

        /** The host whose window this service anchors. */
        @Volatile
        internal var owner: OverlayHost? = null
    }
}
