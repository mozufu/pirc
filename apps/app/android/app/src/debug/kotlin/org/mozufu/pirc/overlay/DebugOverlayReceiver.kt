package org.mozufu.pirc.overlay

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.IOException
import java.util.Calendar
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import org.json.JSONArray
import org.json.JSONObject
import org.mozufu.pirc.background.BackgroundResult
import org.mozufu.pirc.notifications.CompactReads
import org.mozufu.pirc.notifications.OverlaySwitch
import org.mozufu.pirc.notifications.PushNote
import org.mozufu.pirc.notifications.PushReceipt

/**
 * Debug builds only (src/debug): shows the quick-reply overlay in one state with fake
 * data, for the screenshots of docs/design/screenshots/M8-overlay. It runs the push
 * receipt ([PushReceipt]) on a made-up push and then [OverlayLauncher.onReceipt], as
 * push delivery does, so the gate, the switch, the permission and the lock are checked
 * the same way; only the Gateway is fake. No notification is posted.
 *
 * ```
 * adb shell appops set org.mozufu.pirc SYSTEM_ALERT_WINDOW allow
 * adb shell am broadcast -n org.mozufu.pirc/.overlay.DebugOverlayReceiver \
 *   -a org.mozufu.pirc.debug.OVERLAY --es scene question-ready
 * ```
 *
 * Scenes: question-checking, question-ready, question-other, question-confirm,
 * question-sending, question-sent, question-answered, question-expired, question-offline,
 * question-no-control, question-not-sure, run-checking, run-ready, run-sending, run-sent,
 * run-settled, run-not-sure, and `stop`, which closes the overlay, removes the fake
 * Gateway and puts the overlay switch back as it was before the first scene.
 */
class DebugOverlayReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        val scene = intent.getStringExtra("scene") ?: return
        OverlayHost.get(app).close()
        val debug = app.getSharedPreferences("overlay_debug", Context.MODE_PRIVATE)
        val switch = OverlaySwitch.of(app)
        if (scene == "stop") {
            OverlayHost.overrides = null
            if (debug.contains(SAVED_SWITCH)) {
                switch.wanted = debug.getBoolean(SAVED_SWITCH, false)
                debug.edit().remove(SAVED_SWITCH).commit()
            }
            return
        }
        // The switch as Settings → Notifications sets it; the permission stays the system's.
        if (!debug.contains(SAVED_SWITCH)) debug.edit().putBoolean(SAVED_SWITCH, switch.wanted).commit()
        switch.wanted = true
        val uncertain = UncertainSends(app.getSharedPreferences("overlay_uncertain_debug", Context.MODE_PRIVATE))
        app.getSharedPreferences("overlay_uncertain_debug", Context.MODE_PRIVATE).edit().clear().commit()
        val fake = Scene(scene)
        OverlayHost.overrides = OverlayHost.Overrides(
            gateway = fake,
            clientId = "this-phone",
            uncertain = uncertain,
            // A thread per request: a scene's blocked call never holds up the next scene.
            io = Executor { Thread(it).start() },
            sentCloseMillis = 10 * 60_000L,
            afterRender = fake::afterRender,
        )
        // Each scene is its own item, so a new scene never reuses the last one's state.
        val stamp = System.currentTimeMillis().toString()
        val json = if (scene.startsWith("run")) {
            JSONObject().put("title", "Missed").put("body", "").put("tag", "run:$stamp").put("at", 1)
                .put("category", "needs_you")
                .put("target", JSONObject().put("schedules", true).put("scheduleId", "debug").put("runId", stamp))
        } else {
            JSONObject().put("title", "Waiting").put("body", "").put("tag", PushNote.questionTag("debug", "1", stamp))
                .put("at", 1).put("category", "needs_you").put("kind", "interaction_created")
                .put("sessionId", "debug").put("interactionId", stamp).put("interactionEpoch", "1")
                .put("target", JSONObject().put("sessionId", "debug"))
        }
        val note = PushNote.parse(json.toString().toByteArray()) ?: return
        // What push receipt's own read sees: the question open with choices, the run missed.
        val receiptReads = object : CompactReads {
            override fun interaction(sessionId: String, interactionId: String) = BackgroundResult.Done(
                JSONObject().put("state", "pending").put("epoch", "1")
                    .put("question", JSONObject().put("title", "是否只重新執行失敗案例？"))
                    .put("choices", JSONArray().put(JSONObject().put("id", "failed").put("label", "只重跑失敗的 3 個案例"))),
            )

            override fun scheduleRun(scheduleId: String, runId: String) =
                BackgroundResult.Done(JSONObject().put("run", JSONObject().put("state", "missed")))
        }
        val steps = PushReceipt(receiptReads, { emptySet() }).plan(note)
        val started = OverlayLauncher.of(app).onReceipt(note, steps)
        Log.i("PircOverlay", "debug scene $scene started=$started")
    }

    private companion object {
        const val SAVED_SWITCH = "switchBefore"
    }

    /** A fake Gateway that answers as [name] needs; "blocked" calls never return. */
    private class Scene(private val name: String) : OverlayGateway {
        private val main = Handler(Looper.getMainLooper())
        private val forever = CountDownLatch(1)
        private var acted = false
        private var runReads = 0
        private val now = System.currentTimeMillis()

        private fun block(): Nothing {
            forever.await()
            throw IllegalStateException("unreachable")
        }

        private fun at(hour: Int, minute: Int) = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, hour)
            set(Calendar.MINUTE, minute)
        }.timeInMillis

        override fun interaction(sessionId: String, interactionId: String): BackgroundResult {
            if (name == "question-checking") block()
            if (name == "question-offline") return BackgroundResult.Unreachable(IOException("offline"))
            val holder = when (name) {
                "question-other", "question-no-control" -> JSONObject().put("clientId", "imac").put("name", "Office iMac").put("lastActionAt", now - 3_600_000)
                "question-confirm" -> JSONObject().put("clientId", "imac").put("name", "Office iMac").put("lastActionAt", now - 5_000)
                else -> JSONObject().put("clientId", "this-phone").put("name", "Pixel")
            }
            val state = when (name) {
                "question-answered" -> "answered"
                "question-expired" -> "expired"
                else -> "pending"
            }
            return BackgroundResult.Done(
                JSONObject()
                    .put("id", interactionId)
                    .put("sessionName", "檢查 nightly test")
                    .put("state", state)
                    .put("epoch", "1")
                    .put("question", JSONObject().put("kind", "select").put("title", "是否只重新執行失敗案例？"))
                    .put(
                        "choices",
                        JSONArray()
                            .put(JSONObject().put("id", "failed").put("label", "只重跑失敗的 3 個案例"))
                            .put(JSONObject().put("id", "all").put("label", "全部重跑"))
                            .put(JSONObject().put("id", "report").put("label", "先不要重跑，只給我報告")),
                    )
                    .put("expiresAt", now + 14 * 60_000 + 30_000)
                    .put("controlHolder", holder)
                    .put(
                        "answeredBy",
                        if (state == "answered") JSONObject().put("deviceName", "iPad").put("at", at(8, 51)) else JSONObject.NULL,
                    ),
            )
        }

        override fun scheduleRun(scheduleId: String, runId: String): BackgroundResult {
            if (name == "run-checking") block()
            // run-settled: missed when the overlay opens, running by the time "Run now" reads it again.
            val state = if (name == "run-settled" && ++runReads > 1) "running" else "missed"
            return BackgroundResult.Done(
                JSONObject().put(
                    "run",
                    JSONObject().put("id", runId).put("scheduleId", scheduleId).put("title", "每天早上檢查測試")
                        .put("state", state).put("dueAt", now - 41 * 60_000)
                        .put("reason", "排程時 Node 沒有在執行。不會自動補跑。"),
                ),
            )
        }

        override fun takeControl(sessionId: String): BackgroundResult =
            if (name == "question-no-control") BackgroundResult.Refused(409, "lease_owned", "Refused") else BackgroundResult.Done(null)

        override fun answer(sessionId: String, interactionId: String, answer: JSONObject, commandId: String): BackgroundResult =
            when (name) {
                "question-sending" -> block()
                "question-not-sure" -> BackgroundResult.NotSure(commandId, IOException("timeout"))
                else -> BackgroundResult.Done(null)
            }

        override fun allowRun(scheduleId: String, runId: String, commandId: String): BackgroundResult = decision(commandId)

        override fun dismissRun(scheduleId: String, runId: String, commandId: String): BackgroundResult = decision(commandId)

        private fun decision(commandId: String): BackgroundResult = when (name) {
            "run-sending" -> block()
            "run-not-sure" -> BackgroundResult.NotSure(commandId, IOException("timeout"))
            else -> BackgroundResult.Done(null)
        }

        /** Presses what the scene needs once the state is ready (posted: not inside a render). */
        fun afterRender(controller: OverlayController, state: OverlayState) {
            if (acted) return
            when (state) {
                is OverlayState.Question -> {
                    acted = true
                    main.post {
                        controller.select("failed")
                        when (name) {
                            "question-confirm", "question-sending", "question-sent", "question-no-control", "question-not-sure" -> controller.send()
                        }
                    }
                }
                is OverlayState.Run -> {
                    acted = true
                    when (name) {
                        "run-sending", "run-sent", "run-not-sure", "run-settled" -> main.post { controller.decide(RunAction.RUN) }
                    }
                }
                else -> Unit
            }
        }
    }
}
