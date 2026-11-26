package org.mozufu.pirc.overlay

import android.app.Application
import android.app.KeyguardManager
import android.content.Intent
import android.graphics.drawable.GradientDrawable
import android.os.Looper
import android.os.PowerManager
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.TextView
import java.util.concurrent.Executor
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mozufu.pirc.background.BackgroundResult
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadow.api.Shadow
import org.robolectric.shadows.ShadowSettings
import org.robolectric.shadows.ShadowWindowManagerImpl

/** The sheet of each state, and the window's lifecycle in [OverlayHost]. */
@RunWith(RobolectricTestRunner::class)
class OverlayViewTest {
    private val app: Application = RuntimeEnvironment.getApplication()
    private val calls = mutableListOf<String>()
    private val actions = object : OverlayActions {
        override fun select(choiceId: String) {
            calls += "select $choiceId"
        }

        override fun send() {
            calls += "send"
        }

        override fun decide(action: RunAction) {
            calls += "decide $action"
        }

        override fun retry() {
            calls += "retry"
        }

        override fun open() {
            calls += "open"
        }

        override fun close() {
            calls += "close"
        }
    }

    private val choices = listOf(OverlayChoice("a", "Rerun the 3 failures"), OverlayChoice("b", "Rerun all"))
    private fun ready(selected: String? = null, control: OverlayControl = OverlayControl.Mine, sending: Boolean = false) =
        OverlayState.Question("Check nightly test", "Rerun only the failures?", null, choices, selected, null, control, sending = sending)

    private fun render(state: OverlayState, dark: Boolean = false): View {
        val view = OverlayView(app, actions)
        view.render(state, dark)
        return view.root
    }

    private fun View.tagged(tag: String): View? = findViewWithTag(tag)

    private fun View.texts(): List<String> {
        val out = mutableListOf<String>()
        fun walk(v: View) {
            if (v is TextView) out += v.text.toString()
            if (v is ViewGroup) for (i in 0 until v.childCount) walk(v.getChildAt(i))
        }
        walk(this)
        return out
    }

    @Test fun checkingShowsTheTextAndDisablesEveryButton() {
        val root = render(OverlayState.Checking(run = false))
        assertTrue(root.texts().contains("Checking the latest state…"))
        assertFalse(root.tagged("overlay:send")!!.isEnabled)
        assertFalse(root.tagged("overlay:later")!!.isEnabled)
        root.tagged("overlay:send")!!.performClick()
        assertEquals(emptyList<String>(), calls)

        val run = render(OverlayState.Checking(run = true))
        assertFalse(run.tagged("overlay:run")!!.isEnabled)
        assertFalse(run.tagged("overlay:skip")!!.isEnabled)
    }

    @Test fun readyShowsTheChoicesSendAndTheControlSource() {
        val root = render(ready())
        assertNotNull(root.tagged("overlay:choice:a"))
        assertNotNull(root.tagged("overlay:choice:b"))
        assertFalse("no choice yet", root.tagged("overlay:send")!!.isEnabled)
        assertTrue((root.tagged("overlay:footer") as TextView).text.startsWith("Control: this device"))
        root.tagged("overlay:choice:b")!!.performClick()
        assertEquals(listOf("select b"), calls)

        val picked = render(ready(selected = "b", control = OverlayControl.Other("Office iMac", recent = false)))
        assertTrue(picked.tagged("overlay:choice:b")!!.isSelected)
        assertTrue(picked.tagged("overlay:send")!!.isEnabled)
        assertTrue((picked.tagged("overlay:footer") as TextView).text.startsWith("Control: Office iMac"))
        picked.tagged("overlay:send")!!.performClick()
        picked.tagged("overlay:open")!!.performClick()
        picked.tagged("overlay:close")!!.performClick()
        assertEquals(listOf("select b", "send", "open", "close"), calls)
    }

    @Test fun aSendInProgressDisablesTheButtons() {
        val root = render(ready(selected = "a", sending = true))
        assertFalse(root.tagged("overlay:send")!!.isEnabled)
        assertFalse(root.tagged("overlay:choice:a")!!.isEnabled)
        assertTrue(root.texts().contains("Sending…"))
    }

    @Test fun aRecentHolderAsksForASecondPress() {
        val state = ready(selected = "a", control = OverlayControl.Other("Office iMac", recent = true)).copy(confirmTakeover = true)
        val root = render(state)
        assertEquals("Take control and send", (root.tagged("overlay:send") as TextView).text)
    }

    @Test fun eachEndStateHasItsTextAndOnlyItsButtons() {
        fun check(state: OverlayState, text: String, buttons: List<String>) {
            val root = render(state)
            assertTrue("$state: ${root.texts()}", root.texts().any { it.contains(text) })
            for (tag in listOf("overlay:send", "overlay:ok", "overlay:retry", "overlay:open-conversation", "overlay:run", "overlay:skip")) {
                assertEquals("$state $tag", tag in buttons, root.tagged(tag) != null)
            }
        }
        check(OverlayState.Sent(null), "Sent", emptyList())
        check(OverlayState.Sent(RunAction.RUN), "Run started", emptyList())
        check(OverlayState.Sent(RunAction.SKIP), "Skipped", emptyList())
        check(OverlayState.AnsweredElsewhere("iPad", 0L, "Rerun?"), "Answered on iPad", listOf("overlay:ok"))
        check(OverlayState.Expired("Rerun?"), "expired", listOf("overlay:ok"))
        check(OverlayState.Offline(run = false), "Can't check", listOf("overlay:retry", "overlay:open-conversation"))
        check(OverlayState.NoControl("Office iMac"), "Office iMac controls", listOf("overlay:open-conversation"))
        check(OverlayState.NotSure(run = false), "Not sure it arrived", listOf("overlay:open-conversation"))
        check(OverlayState.NotSure(run = true), "Not sure the decision arrived", listOf("overlay:open-conversation"))
        check(OverlayState.RunSettled("running"), "already started", listOf("overlay:ok"))
        check(OverlayState.Run("Morning tests", 0L, "The node was not running."), "Morning tests", listOf("overlay:run", "overlay:skip"))
    }

    @Test fun touchesUnderAnotherWindowAreDropped() {
        val root = render(ready(selected = "a"))
        assertTrue(root.filterTouchesWhenObscured)
        for (tag in listOf("overlay:send", "overlay:later", "overlay:choice:a", "overlay:choice:b", "overlay:open", "overlay:close")) {
            assertTrue(tag, root.tagged(tag)!!.filterTouchesWhenObscured)
        }
        val run = render(OverlayState.Run("Morning tests", 0L, null))
        assertTrue(run.tagged("overlay:run")!!.filterTouchesWhenObscured)
        assertTrue(run.tagged("overlay:skip")!!.filterTouchesWhenObscured)
        // A tap on Send works, and the same tap while another window covers it does nothing.
        // Attached to a window and laid out, so a tap becomes a click.
        Robolectric.buildActivity(android.app.Activity::class.java).setup().get().setContentView(root)
        shadowOf(Looper.getMainLooper()).idle()
        val send = root.tagged("overlay:send")!!
        fun tap(flags: Int) {
            for ((action, time) in listOf(MotionEvent.ACTION_DOWN to 0L, MotionEvent.ACTION_UP to 10L)) {
                val event = MotionEvent.obtain(
                    0, time, action, 1,
                    arrayOf(MotionEvent.PointerProperties().apply { id = 0 }),
                    arrayOf(MotionEvent.PointerCoords().apply { x = 5f; y = 5f }),
                    0, 0, 1f, 1f, 0, 0, 0, flags,
                )
                send.dispatchTouchEvent(event)
            }
            shadowOf(Looper.getMainLooper()).idle()
        }
        tap(0)
        assertEquals(listOf("send"), calls)
        calls.clear()
        tap(MotionEvent.FLAG_WINDOW_IS_OBSCURED)
        assertEquals(emptyList<String>(), calls)
    }

    @Test fun theMinuteRefreshChangesOnlyTheExpiryLine() {
        val view = OverlayView(app, actions)
        val state = ready(selected = "a").copy(expiresAt = System.currentTimeMillis() + 10 * 60_000 + 30_000)
        view.render(state, false)
        val send = view.root.tagged("overlay:send")
        assertTrue(view.root.texts().contains("Expires in 10 min"))
        view.refreshExpiry(state.copy(expiresAt = System.currentTimeMillis() + 3 * 60_000 + 30_000))
        assertTrue(view.root.texts().contains("Expires in 3 min"))
        // The same views: the sheet was not built again.
        assertTrue(send === view.root.tagged("overlay:send"))
    }

    @Test fun aNewConfigurationIsUsedOnTheNextRender() {
        val view = OverlayView(app, actions)
        view.render(OverlayState.Checking(run = false), false)
        assertTrue(view.root.texts().contains("Checking the latest state…"))
        val config = android.content.res.Configuration(app.resources.configuration).apply { setLocale(java.util.Locale.TAIWAN) }
        view.updateContext(app.createConfigurationContext(config))
        view.render(OverlayState.Checking(run = false), false)
        assertTrue(view.root.texts().contains("確認最新狀態…"))
    }

    @Test fun lightAndDarkUseTheirTokenColours() {
        val light = render(ready(selected = "a"), dark = false) as ViewGroup
        val dark = render(ready(selected = "a"), dark = true) as ViewGroup
        fun sheet(root: ViewGroup) = (root.getChildAt(0).background as GradientDrawable).color!!.defaultColor
        assertEquals(OverlayTokens.light.surfaceLayer, sheet(light))
        assertEquals(OverlayTokens.dark.surfaceLayer, sheet(dark))
        fun send(root: View) = (root.tagged("overlay:send")!!.background as GradientDrawable).color!!.defaultColor
        assertEquals(OverlayTokens.light.actionPrimary, send(light))
        assertEquals(OverlayTokens.dark.actionPrimary, send(dark))
        assertEquals(OverlayTokens.dark.actionOnPrimary, (dark.tagged("overlay:send") as TextView).currentTextColor)
    }

    // ---- the window ----------------------------------------------------------------

    private val item = OverlayItem.Question("s1", "q1", "3", "tag-q")
    private val other = OverlayItem.Run("sc1", "r1", "tag-r")

    private val gateway = object : OverlayGateway {
        override fun interaction(sessionId: String, interactionId: String) = BackgroundResult.Done(
            JSONObject().put("state", "pending").put("epoch", "3")
                .put("question", JSONObject().put("title", "Rerun?"))
                .put("choices", JSONArray().put(JSONObject().put("id", "a").put("label", "A"))),
        )

        override fun scheduleRun(scheduleId: String, runId: String) = BackgroundResult.Done(
            JSONObject().put("run", JSONObject().put("state", "missed").put("title", "Morning tests")),
        )

        override fun takeControl(sessionId: String) = BackgroundResult.Done(null)

        override fun answer(sessionId: String, interactionId: String, answer: JSONObject, commandId: String) =
            BackgroundResult.Done(null)

        override fun allowRun(scheduleId: String, runId: String, commandId: String) = BackgroundResult.Done(null)

        override fun dismissRun(scheduleId: String, runId: String, commandId: String) = BackgroundResult.Done(null)
    }

    @Before fun unlocked() {
        ShadowSettings.setCanDrawOverlays(true)
        shadowOf(app.getSystemService(KeyguardManager::class.java)).setKeyguardLocked(false)
        shadowOf(app.getSystemService(PowerManager::class.java)).turnScreenOn(true)
        OverlayHost.overrides = OverlayHost.Overrides(gateway, "phone", io = Executor { it.run() })
    }

    @After fun reset() {
        OverlayHost.overrides = null
        OverlayService.owner = null
    }

    private fun windowViews(): List<View> =
        Shadow.extract<ShadowWindowManagerImpl>(app.getSystemService(WindowManager::class.java)).views

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    private fun shown(host: OverlayHost, show: OverlayItem = item) = host.also {
        it.show(show)
        idle()
    }

    @Test fun theWindowIsANonFocusableOverlayRemovedOnClose() {
        val host = shown(OverlayHost(app, anchor = false))
        val window = windowViews().single()
        val params = window.layoutParams as WindowManager.LayoutParams
        assertEquals(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, params.type)
        assertTrue(params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE != 0)
        assertTrue(params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL != 0)
        assertEquals(0, params.flags and WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH)
        // The window is the sheet: no transparent margin inside it takes touches.
        assertEquals(0, window.paddingTop + window.paddingBottom + window.paddingLeft + window.paddingRight)
        assertTrue(params.y > 0)
        assertEquals(item, host.shown)
        assertTrue(host.isListening)
        assertNotNull("ready after the read", window.findViewWithTag<View>("overlay:choice:a"))

        window.findViewWithTag<View>("overlay:close").performClick()
        assertEquals(emptyList<View>(), windowViews())
        assertNull(host.shown)
        assertFalse("receiver and callbacks unregistered", host.isListening)
        host.close()
        assertEquals(emptyList<View>(), windowViews())
    }

    @Test fun aSecondItemReplacesTheFirstInTheSameWindow() {
        val host = shown(OverlayHost(app, anchor = false))
        shown(host, other)
        assertEquals(1, windowViews().size)
        assertEquals(other, host.shown)
        assertNotNull(windowViews().single().findViewWithTag<View>("overlay:run"))
        host.close()
    }

    @Test fun itClosesAfterTheIdleTimeoutAndWhenTheScreenGoesOff() {
        val host = shown(OverlayHost(app, anchor = false))
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(OverlayHost.IDLE_TIMEOUT))
        assertEquals(emptyList<View>(), windowViews())
        assertFalse(host.isListening)

        shown(host)
        assertEquals(1, windowViews().size)
        app.sendBroadcast(Intent(Intent.ACTION_SCREEN_OFF))
        idle()
        assertEquals(emptyList<View>(), windowViews())
        assertNull(host.shown)
        assertFalse(host.isListening)
    }

    @Test fun aPushForAnotherItemWhileASendIsOutKeepsTheOverlay() {
        val pending = ArrayDeque<Runnable>()
        OverlayHost.overrides = OverlayHost.Overrides(gateway, "phone", io = Executor { pending.addLast(it) })
        fun runAll() {
            while (pending.isNotEmpty()) pending.removeFirst().run()
            idle()
        }
        val host = OverlayHost(app, anchor = false)
        host.show(item)
        runAll() // prepare, then the first read
        runAll()
        val window = windowViews().single()
        window.findViewWithTag<View>("overlay:choice:a").performClick()
        window.findViewWithTag<View>("overlay:send").performClick()
        // The send's read is queued, not run: a send is out.
        assertEquals(1, pending.size)
        host.show(other)
        pending.removeLast().run() // only the new item's preparation
        idle()
        assertEquals(item, host.shown)
        assertEquals(1, windowViews().size)
        host.close()
    }

    @Test fun aLockedScreenOrNoPermissionAddsNoWindow() {
        val host = OverlayHost(app, anchor = false)
        shadowOf(app.getSystemService(KeyguardManager::class.java)).setKeyguardLocked(true)
        shown(host)
        assertEquals(emptyList<View>(), windowViews())

        shadowOf(app.getSystemService(KeyguardManager::class.java)).setKeyguardLocked(false)
        ShadowSettings.setCanDrawOverlays(false)
        shown(host)
        assertEquals(emptyList<View>(), windowViews())
        assertNull(host.shown)
        assertFalse(host.isListening)
    }

    private fun anchorOf(host: OverlayHost): Intent {
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(2))
        val intent = shadowOf(app).nextStartedService
        assertEquals(OverlayService::class.java.name, intent.component!!.className)
        assertEquals(host, OverlayService.owner)
        return intent
    }

    @Test fun theAnchorServiceStartsWithTheWindowAndStopsOnClose() {
        val host = shown(OverlayHost(app, anchor = true))
        anchorOf(host)
        host.close()
        assertEquals(OverlayService::class.java.name, shadowOf(app).nextStoppedService.component!!.className)
    }

    @Test fun stoppingTheAnchorRemovesItsWindow() {
        val host = shown(OverlayHost(app, anchor = true))
        val anchor = Robolectric.buildService(OverlayService::class.java, anchorOf(host)).create().startCommand(0, 1)
        assertEquals(1, windowViews().size)
        anchor.destroy()
        assertEquals(emptyList<View>(), windowViews())
        assertNull(host.shown)
        assertFalse(host.isListening)
    }

    @Test fun aLateStopOfAnOldAnchorLeavesTheNewWindow() {
        val host = shown(OverlayHost(app, anchor = true))
        val old = Robolectric.buildService(OverlayService::class.java, anchorOf(host)).create().startCommand(0, 1)
        host.close()
        shown(host, other)
        anchorOf(host)
        old.destroy()
        assertEquals(1, windowViews().size)
        assertEquals(other, host.shown)
        host.close()
    }
}
