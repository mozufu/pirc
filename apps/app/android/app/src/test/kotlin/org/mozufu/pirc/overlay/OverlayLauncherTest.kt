package org.mozufu.pirc.overlay

import android.app.Application
import android.app.KeyguardManager
import android.content.Context
import android.os.PowerManager
import java.io.IOException
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mozufu.pirc.background.BackgroundResult
import org.mozufu.pirc.notifications.CompactReads
import org.mozufu.pirc.notifications.OverlaySwitch
import org.mozufu.pirc.notifications.PushNote
import org.mozufu.pirc.notifications.PushReceipt
import org.mozufu.pirc.notifications.ReceiptStep
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf

/** When a push opens the overlay, and when it gets only its notification (the fallback). */
@RunWith(RobolectricTestRunner::class)
class OverlayLauncherTest {
    private val app: Application = RuntimeEnvironment.getApplication()
    private val tag = PushNote.questionTag("s1", "3", "q1")
    private val question = PushNote.parse(
        """{"title":"Build is waiting for you","body":"Rerun?","tag":"$tag","target":{"sessionId":"s1"},
           "at":1,"category":"needs_you","kind":"interaction_created","sessionId":"s1",
           "interactionId":"q1","interactionEpoch":"3",
           "choices":[{"id":"payload","label":"From the payload"}]}""".toByteArray(),
    )!!
    private val missed = PushNote.parse(
        """{"title":"Morning tests was missed","body":"Allow it?","tag":"run:r1","at":1,"category":"needs_you",
           "target":{"schedules":true,"scheduleId":"sc1","runId":"r1"}}""".toByteArray(),
    )!!
    private val done = PushNote.parse(
        """{"title":"Morning tests finished","body":"Open it","tag":"session:s9","at":1,"category":"done",
           "target":{"sessionId":"s9"}}""".toByteArray(),
    )!!
    private val approval = PushNote.parse(
        """{"title":"A pot asks","body":"Model?","tag":"approval:a1","at":1,"category":"needs_you",
           "target":{"approvalId":"a1"}}""".toByteArray(),
    )!!

    private val prefs = app.getSharedPreferences("overlay-switch-test", Context.MODE_PRIVATE)
    private var allowed = true
    private val switch = OverlaySwitch(prefs) { allowed }

    /** Records what the launcher asks of the overlay host. */
    private class Display : OverlayDisplay {
        override var shown: OverlayItem? = null
        val showed = mutableListOf<OverlayItem>()
        val rechecked = mutableListOf<OverlayItem>()

        override fun show(item: OverlayItem) {
            showed += item
        }

        override fun recheck(item: OverlayItem) {
            rechecked += item
        }
    }

    private val display = Display()

    private fun launcher(unlocked: Boolean = true) = OverlayLauncher(display, { switch.on }, { unlocked })

    private fun started(): OverlayItem? = display.showed.removeFirstOrNull()

    /** What push receipt's read returns: by default the question open with 2 choices, the run missed. */
    private var interaction: BackgroundResult = pending(2)
    private var run: BackgroundResult = runIn("missed")

    private fun pending(choices: Int) = BackgroundResult.Done(
        JSONObject().put("state", "pending").put("epoch", "3")
            .put("question", JSONObject().put("title", "Rerun?"))
            .put(
                "choices",
                JSONArray().apply { for (i in 1..choices) put(JSONObject().put("id", "c$i").put("label", "C$i")) },
            ),
    )

    private fun runIn(state: String) = BackgroundResult.Done(JSONObject().put("run", JSONObject().put("state", state)))

    private val reads = object : CompactReads {
        override fun interaction(sessionId: String, interactionId: String) = interaction

        override fun scheduleRun(scheduleId: String, runId: String) = run
    }

    /** The receipt's steps for [note]: what push delivery hands the launcher. */
    private fun steps(note: PushNote) = PushReceipt(reads, { emptySet() }).plan(note)

    private fun OverlayLauncher.onPush(note: PushNote) = onReceipt(note, steps(note))

    @Test fun aQuestionOpensTheOverlayWhenWantedAllowedAndUnlocked() {
        switch.wanted = true
        assertTrue(launcher().onPush(question))
        // The overlay is told only IDs: never the payload's choices.
        assertEquals(OverlayItem.Question("s1", "q1", "3", tag), started())
    }

    @Test fun aMissedRunOpensTheOverlay() {
        switch.wanted = true
        assertTrue(launcher().onPush(missed))
        assertEquals(OverlayItem.Run("sc1", "r1", "run:r1"), started())
    }

    @Test fun otherPushesNeverOpenIt() {
        switch.wanted = true
        assertFalse(launcher().onPush(done))
        assertFalse(launcher().onPush(approval))
        assertNull(started())
    }

    @Test fun theSwitchOffFallsBackToTheNotification() {
        switch.wanted = false
        assertFalse(launcher().onPush(question))
        assertNull(started())
        assertTrue(notificationShown(question))
    }

    @Test fun noDisplayOverOtherAppsFallsBackToTheNotification() {
        switch.wanted = true
        allowed = false
        assertFalse(launcher().onPush(question))
        assertFalse(launcher().onPush(missed))
        assertNull(started())
        assertTrue(notificationShown(question))
    }

    @Test fun aLockedScreenFallsBackToTheNotification() {
        switch.wanted = true
        val keyguard = shadowOf(app.getSystemService(KeyguardManager::class.java))
        val power = shadowOf(app.getSystemService(PowerManager::class.java))
        power.turnScreenOn(true)
        keyguard.setKeyguardLocked(true)
        val real = OverlayLauncher(display, { switch.on }) { OverlayGate.unlocked(app) }
        assertFalse(OverlayGate.unlocked(app))
        assertFalse(real.onPush(question))
        // The screen is off, though not locked: also the notification only.
        keyguard.setKeyguardLocked(false)
        power.turnScreenOn(false)
        assertFalse(OverlayGate.unlocked(app))
        assertNull(started())
        assertTrue(notificationShown(question))

        assertFalse(real.onPush(missed))
        assertNull(started())

        power.turnScreenOn(true)
        assertTrue(OverlayGate.unlocked(app))
        assertTrue(real.onPush(question))
    }

    @Test fun aPushAboutTheQuestionOnScreenReadsItAgain() {
        val answered = PushNote.parse(
            """{"title":"Answered","body":"","tag":"$tag","at":2,"kind":"interaction_answered","sessionId":"s1",
               "interactionId":"q1","interactionEpoch":"3","target":{"sessionId":"s1"}}""".toByteArray(),
        )!!
        val shown = OverlayItem.Question("s1", "q1", "3", tag)
        assertFalse(launcher().onPush(answered))
        assertEquals(emptyList<OverlayItem>(), display.rechecked)
        display.shown = shown
        assertFalse(launcher().onPush(answered))
        assertEquals(listOf(shown), display.rechecked)
        assertNull(started())
    }

    @Test fun aQuietHoursPushGetsOnlyItsNotification() {
        switch.wanted = true
        val silent = PushNote.parse(
            """{"title":"Waiting","body":"Rerun?","tag":"$tag","target":{"sessionId":"s1"},"at":1,
               "category":"needs_you","silent":true,"kind":"interaction_created","sessionId":"s1",
               "interactionId":"q1","interactionEpoch":"3"}""".toByteArray(),
        )!!
        assertFalse(launcher().onPush(silent))
        assertNull(started())
        assertTrue(notificationShown(silent))
    }

    @Test fun aRunThatFailedOrFinishedGetsOnlyItsNotification() {
        // Failed, finished and waiting runs without a session share the missed run's target.
        switch.wanted = true
        for (state in listOf("failed", "completed", "waiting_input", "running")) {
            run = runIn(state)
            assertFalse(state, launcher().onPush(missed))
        }
        assertNull(started())
    }

    @Test fun anUnreadableStateGetsOnlyTheNotification() {
        switch.wanted = true
        interaction = BackgroundResult.Unreachable(IOException("offline"))
        run = BackgroundResult.Refused(502, "node_offline", "Offline")
        assertFalse(launcher().onPush(question))
        assertFalse(launcher().onPush(missed))
        assertNull(started())
        assertTrue(steps(question).single() is ReceiptStep.Show)
        assertTrue(steps(missed).single() is ReceiptStep.Show)
    }

    @Test fun aQuestionWithoutChoicesHereGetsOnlyTheNotification() {
        switch.wanted = true
        interaction = pending(4)
        assertFalse(launcher().onPush(question))
        interaction = pending(0)
        assertFalse(launcher().onPush(question))
        interaction = pending(3)
        assertTrue(launcher().onPush(question))
    }

    @Test fun theGateIsAFunctionOfTheReceiptTheSwitchAndTheLock() {
        val shown = steps(question)
        assertEquals(null, OverlayGate.itemFor(question, shown, switchOn = false, unlocked = true))
        assertEquals(null, OverlayGate.itemFor(question, shown, switchOn = true, unlocked = false))
        assertEquals(OverlayItem.Question("s1", "q1", "3", tag), OverlayGate.itemFor(question, shown, switchOn = true, unlocked = true))
        assertEquals(null, OverlayGate.itemFor(question, emptyList(), switchOn = true, unlocked = true))
        assertEquals(null, OverlayGate.itemFor(approval, steps(approval), switchOn = true, unlocked = true))
    }

    /** The step 3 receipt shows the question's notification whatever the overlay does. */
    private fun notificationShown(note: PushNote): Boolean {
        val reads = object : CompactReads {
            override fun interaction(sessionId: String, interactionId: String) = BackgroundResult.Done(
                JSONObject().put("state", "pending").put("epoch", "3")
                    .put("question", JSONObject().put("title", "Rerun?"))
                    .put("choices", JSONArray().put(JSONObject().put("id", "a").put("label", "A"))),
            )

            override fun scheduleRun(scheduleId: String, runId: String) = BackgroundResult.Done(null)
        }
        return PushReceipt(reads, { emptySet() }).plan(note).single() is ReceiptStep.Show
    }
}
