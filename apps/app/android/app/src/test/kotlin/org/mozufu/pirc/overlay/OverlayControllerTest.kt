package org.mozufu.pirc.overlay

import android.content.Context
import java.io.IOException
import java.util.concurrent.Executor
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mozufu.pirc.background.BackgroundResult
import org.mozufu.pirc.notifications.OpenTarget
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/** Each state of the overlay, the lease and command ID of a send, and missed runs. */
@RunWith(RobolectricTestRunner::class)
class OverlayControllerTest {
    private var now = 10_000_000L
    private val question = OverlayItem.Question("s1", "q1", "3", "tag-q")
    private val run = OverlayItem.Run("sc1", "r1", "tag-r")
    private val prefs = RuntimeEnvironment.getApplication().getSharedPreferences("overlay-test", Context.MODE_PRIVATE)
    private val uncertain = UncertainSends(prefs)

    private class Gateway : OverlayGateway {
        val reads = ArrayDeque<BackgroundResult>()
        val runReads = ArrayDeque<BackgroundResult>()
        var takeover: BackgroundResult = BackgroundResult.Done(JSONObject())
        var send: BackgroundResult = BackgroundResult.Done(JSONObject())
        val calls = mutableListOf<String>()
        val answers = mutableListOf<JSONObject>()
        private var lastRead: BackgroundResult = BackgroundResult.Unreachable(IOException("no read queued"))
        private var lastRun: BackgroundResult = BackgroundResult.Unreachable(IOException("no read queued"))

        /** The queued reads in order; then the last one again, as a server that did not change. */
        override fun interaction(sessionId: String, interactionId: String): BackgroundResult {
            calls += "read $sessionId $interactionId"
            return (reads.removeFirstOrNull() ?: lastRead).also { lastRead = it }
        }

        override fun scheduleRun(scheduleId: String, runId: String): BackgroundResult {
            calls += "run $scheduleId $runId"
            return (runReads.removeFirstOrNull() ?: lastRun).also { lastRun = it }
        }

        override fun takeControl(sessionId: String): BackgroundResult {
            calls += "takeControl $sessionId"
            return takeover
        }

        override fun answer(sessionId: String, interactionId: String, answer: JSONObject, commandId: String): BackgroundResult {
            calls += "answer $sessionId $interactionId $commandId"
            answers += answer
            return send
        }

        override fun allowRun(scheduleId: String, runId: String, commandId: String): BackgroundResult {
            calls += "allowRun $scheduleId $runId $commandId"
            return send
        }

        override fun dismissRun(scheduleId: String, runId: String, commandId: String): BackgroundResult {
            calls += "dismissRun $scheduleId $runId $commandId"
            return send
        }
    }

    private class Effects : OverlayEffects {
        val states = mutableListOf<OverlayState>()
        var closed = 0
        val removed = mutableListOf<String>()
        val opened = mutableListOf<OpenTarget>()

        override fun render(state: OverlayState) {
            states += state
        }

        override fun close() {
            closed++
        }

        override fun removeNotification(tag: String) {
            removed += tag
        }

        override fun open(target: OpenTarget) {
            opened += target
        }
    }

    private val gateway = Gateway()
    private val effects = Effects()
    private val timers = mutableListOf<Pair<Long, Runnable>>()
    private var ids = 0
    private val direct = Executor { it.run() }

    private fun controller(item: OverlayItem = question, io: Executor = direct) = OverlayController(
        item = item,
        clientId = "phone",
        gateway = gateway,
        uncertain = uncertain,
        effects = effects,
        io = io,
        main = direct,
        later = { delay, task ->
            val entry = delay to task
            timers += entry
            ({ timers.remove(entry) })
        },
        now = { now },
        newCommandId = { "command-${++ids}" },
    )

    private fun compact(
        state: String = "pending",
        epoch: String = "3",
        choices: Int = 3,
        holder: JSONObject? = null,
        expiresAt: Long? = now + 14 * 60_000,
        answeredBy: JSONObject? = null,
        other: Boolean = false,
    ) = BackgroundResult.Done(
        JSONObject()
            .put("id", "q1")
            .put("sessionName", "Check nightly test")
            .put("state", state)
            .put("epoch", epoch)
            .put("question", JSONObject().put("kind", "select").put("title", "Rerun only the failures?"))
            .put(
                "choices",
                JSONArray().apply {
                    for (i in 1..choices) put(JSONObject().put("id", "c$i").put("label", "Choice $i"))
                    if (other) put(JSONObject().put("id", "Other").put("label", "Other").put("other", true))
                },
            )
            .put("expiresAt", expiresAt ?: JSONObject.NULL)
            .put("controlHolder", holder ?: JSONObject.NULL)
            .put("answeredBy", answeredBy ?: JSONObject.NULL),
    )

    private fun missed(state: String = "missed") = BackgroundResult.Done(
        JSONObject().put(
            "run",
            JSONObject().put("id", "r1").put("scheduleId", "sc1").put("title", "Morning tests")
                .put("state", state).put("dueAt", now - 41 * 60_000).put("reason", "The node was not running."),
        ),
    )

    private val ready get() = effects.states.last() as OverlayState.Question

    // ---- checking and ready ---------------------------------------------------------

    @Test fun opensCheckingWithEveryButtonOffThenShowsTheCompactChoices() {
        val pending = mutableListOf<Runnable>()
        val c = controller(io = Executor { pending += it })
        c.check()
        assertEquals(listOf<OverlayState>(OverlayState.Checking(run = false)), effects.states)

        gateway.reads += compact()
        pending.single().run()
        val state = ready
        assertEquals(listOf("c1", "c2", "c3"), state.choices.map { it.id })
        assertEquals("Check nightly test", state.sessionName)
        assertEquals("Rerun only the failures?", state.title)
        assertNull(state.selected)
        assertFalse("nothing is preselected", state.canSend)
        assertEquals(OverlayControl.Mine, state.control)
    }

    @Test fun otherIsOfferedButNotCounted() {
        gateway.reads += compact(choices = 3, other = true)
        controller().check()
        assertEquals(listOf("c1", "c2", "c3", "Other"), ready.choices.map { it.id })
    }

    @Test fun moreThanThreeChoicesBesideOtherAreNotOffered() {
        gateway.reads += compact(choices = 4, other = true)
        controller().check()
        assertEquals(emptyList<OverlayChoice>(), ready.choices)
    }

    @Test fun moreThanThreeChoicesAreNotOffered() {
        gateway.reads += compact(choices = 4)
        controller().check()
        assertEquals(emptyList<OverlayChoice>(), ready.choices)
    }

    @Test fun theControlSourceComesFromTheLeasesClientId() {
        gateway.reads += compact(holder = JSONObject().put("clientId", "phone").put("name", "Pixel"))
        gateway.reads += compact(holder = JSONObject().put("clientId", "web-1").put("name", "Office iMac").put("lastActionAt", now - 60_000))
        gateway.reads += compact(holder = JSONObject().put("clientId", "web-1").put("lastActionAt", now - 5_000))
        val c = controller()

        c.check()
        assertEquals(OverlayControl.Mine, ready.control)
        c.check()
        assertEquals(OverlayControl.Other("Office iMac", recent = false, clientId = "web-1"), ready.control)
        c.check()
        assertEquals(OverlayControl.Other(null, recent = true, clientId = "web-1"), ready.control)
    }

    // ---- sending ----------------------------------------------------------------------

    @Test fun aSendWithControlHereSendsTheAnswerWithACommandIdAndClosesBySelf() {
        gateway.reads += compact()
        val c = controller()
        c.check()
        c.select("c2")
        c.send()

        // Read on open, read again before the send.
        assertEquals(listOf("read s1 q1", "read s1 q1", "answer s1 q1 command-1"), gateway.calls)
        assertEquals("c2", gateway.answers.single().getString("value"))
        assertEquals(1, gateway.answers.single().length())
        assertEquals(OverlayState.Sent(null), effects.states.last())
        assertTrue(effects.states.any { it is OverlayState.Question && it.sending })
        assertEquals(listOf("tag-q"), effects.removed)
        assertNull("the outcome is known", uncertain.commandOf(question.key))
        assertEquals(0, effects.closed)
        timers.single().second.run()
        assertEquals(1, effects.closed)
    }

    @Test fun aSendTakesTheLeaseFirstWhenAnotherDeviceHoldsIt() {
        gateway.reads += compact(holder = JSONObject().put("clientId", "web-1").put("name", "Office iMac"))
        val c = controller()
        c.check()
        c.select("c1")
        c.send()

        assertEquals(listOf("read s1 q1", "read s1 q1", "takeControl s1", "answer s1 q1 command-1"), gateway.calls)
        assertEquals(OverlayState.Sent(null), effects.states.last())
    }

    @Test fun aHolderThatActedLatelyIsConfirmedWithASecondPressNotADoubleTap() {
        gateway.reads += compact(holder = JSONObject().put("clientId", "web-1").put("name", "Office iMac").put("lastActionAt", now - 5_000))
        val c = controller()
        c.check()
        c.select("c1")
        c.send()
        assertTrue(ready.confirmTakeover)
        assertEquals("c1", ready.selected)
        assertEquals(listOf("read s1 q1", "read s1 q1"), gateway.calls)

        // A second tap right away is ignored.
        now += 100
        c.send()
        assertEquals(2, gateway.calls.size)
        assertTrue(ready.confirmTakeover)

        now += OverlayController.CONFIRM_GUARD_MILLIS
        c.send()
        assertEquals(listOf("read s1 q1", "read s1 q1", "read s1 q1", "takeControl s1", "answer s1 q1 command-1"), gateway.calls)
        assertEquals(OverlayState.Sent(null), effects.states.last())
    }

    @Test fun aRecentHolderWithoutANameIsStillAskedAbout() {
        gateway.reads += compact(holder = JSONObject().put("clientId", "web-1").put("lastActionAt", now - 5_000))
        val c = controller()
        c.check()
        c.select("c1")
        c.send()
        assertTrue(ready.confirmTakeover)
        assertTrue(gateway.calls.none { it.startsWith("takeControl") || it.startsWith("answer") })

        now += OverlayController.CONFIRM_GUARD_MILLIS
        c.send()
        assertEquals(1, gateway.calls.count { it.startsWith("answer") })
    }

    @Test fun anAgreementForOneHolderDoesNotCoverAnother() {
        gateway.reads += compact(holder = JSONObject().put("clientId", "web-1").put("lastActionAt", now - 5_000))
        gateway.reads += compact(holder = JSONObject().put("clientId", "web-1").put("lastActionAt", now - 5_000))
        gateway.reads += compact(holder = JSONObject().put("clientId", "web-2").put("lastActionAt", now - 1_000))
        val c = controller()
        c.check()
        c.select("c1")
        c.send()
        assertTrue(ready.confirmTakeover)
        now += OverlayController.CONFIRM_GUARD_MILLIS
        c.send()
        // Another nameless device took control meanwhile: asked again, nothing sent.
        assertTrue(ready.confirmTakeover)
        assertEquals(OverlayControl.Other(null, recent = true, clientId = "web-2"), ready.control)
        assertTrue(gateway.calls.none { it.startsWith("takeControl") || it.startsWith("answer") })
    }

    @Test fun aHolderRecentOnlyWhenTheOverlayOpenedIsNotAskedAbout() {
        // Recent at open; by the send it has been idle for a minute.
        gateway.reads += compact(holder = JSONObject().put("clientId", "web-1").put("name", "Office iMac").put("lastActionAt", now - 5_000))
        gateway.reads += compact(holder = JSONObject().put("clientId", "web-1").put("name", "Office iMac").put("lastActionAt", now - 60_000))
        val c = controller()
        c.check()
        assertEquals(OverlayControl.Other("Office iMac", recent = true, clientId = "web-1"), ready.control)
        c.select("c1")
        c.send()
        assertEquals(listOf("read s1 q1", "read s1 q1", "takeControl s1", "answer s1 q1 command-1"), gateway.calls)
        assertFalse(effects.states.any { it is OverlayState.Question && it.confirmTakeover })
    }

    @Test fun aHolderThatActedSinceTheOverlayOpenedIsAskedAboutFirst() {
        gateway.reads += compact(holder = JSONObject().put("clientId", "web-1").put("name", "Office iMac").put("lastActionAt", now - 60_000))
        gateway.reads += compact(holder = JSONObject().put("clientId", "web-1").put("name", "Office iMac").put("lastActionAt", now - 2_000))
        val c = controller()
        c.check()
        c.select("c1")
        c.send()
        assertTrue(ready.confirmTakeover)
        assertEquals(OverlayControl.Other("Office iMac", recent = true, clientId = "web-1"), ready.control)
        assertTrue(gateway.calls.none { it.startsWith("takeControl") || it.startsWith("answer") })
    }

    @Test fun aQuestionAnsweredBeforeTheSendShowsThatAndSendsNothing() {
        gateway.reads += compact()
        gateway.reads += compact(state = "answered", answeredBy = JSONObject().put("deviceName", "iPad").put("at", 5L))
        val c = controller()
        c.check()
        c.select("c1")
        c.send()
        assertEquals(OverlayState.AnsweredElsewhere("iPad", 5L, "Rerun only the failures?", "Check nightly test"), effects.states.last())
        assertTrue(gateway.calls.none { it.startsWith("answer") })
    }

    @Test fun aTakeover5xxIsOfflineNotNoControl() {
        gateway.reads += compact(holder = JSONObject().put("clientId", "web-1").put("name", "Office iMac"))
        gateway.takeover = BackgroundResult.Refused(503, "node_offline", "Offline")
        val c = controller()
        c.check()
        c.select("c1")
        c.send()
        assertEquals(OverlayState.Offline(run = false), effects.states.last())
        assertTrue(gateway.calls.none { it.startsWith("answer") })
    }

    @Test fun aRefusedTakeoverShowsTheHolderAndSendsNoAnswer() {
        gateway.reads += compact(holder = JSONObject().put("clientId", "web-1").put("name", "Office iMac"))
        gateway.takeover = BackgroundResult.Refused(409, "lease_owned", "Another user")
        val c = controller()
        c.check()
        c.select("c1")
        c.send()

        assertEquals(OverlayState.NoControl("Office iMac"), effects.states.last())
        assertTrue(gateway.calls.none { it.startsWith("answer") })
        c.openConversation()
        assertEquals(listOf(OpenTarget.question("s1", "q1", "3")), effects.opened)
    }

    @Test fun anUnreachableTakeoverIsOfflineAndSendsNoAnswer() {
        gateway.reads += compact(holder = JSONObject().put("clientId", "web-1"))
        gateway.takeover = BackgroundResult.Unreachable(IOException("offline"))
        val c = controller()
        c.check()
        c.select("c1")
        c.send()

        assertEquals(OverlayState.Offline(run = false), effects.states.last())
        assertTrue(gateway.calls.none { it.startsWith("answer") })
        assertNull(uncertain.commandOf(question.key))
    }

    @Test fun notSureKeepsTheCommandIdAndNeverSendsThatItemAgain() {
        gateway.reads += compact()
        gateway.send = BackgroundResult.NotSure("command-1", IOException("timeout"))
        val c = controller()
        c.check()
        c.select("c1")
        c.send()
        assertEquals(OverlayState.NotSure(run = false), effects.states.last())
        assertEquals("command-1", uncertain.commandOf(question.key))
        assertEquals(listOf<String>(), effects.removed)

        // The service ends; a new overlay for the same item, still pending.
        c.dispose()
        gateway.reads += compact()
        val again = controller()
        again.check()
        assertEquals(OverlayState.NotSure(run = false), effects.states.last())
        again.select("c1")
        again.send()
        assertEquals(1, gateway.calls.count { it.startsWith("answer") })
        // Once the question is answered (by that send, or elsewhere) the mark goes.
        gateway.reads += compact(state = "answered", answeredBy = JSONObject().put("deviceName", "Pixel").put("at", now))
        again.check()
        assertEquals(OverlayState.AnsweredElsewhere("Pixel", now, "Rerun only the failures?", "Check nightly test"), effects.states.last())
        assertNull(uncertain.commandOf(question.key))
    }

    @Test fun aRefusedAnswerReadsTheStateAgain() {
        gateway.reads += compact()
        gateway.reads += compact()
        gateway.reads += compact(state = "answered", answeredBy = JSONObject().put("deviceName", "iPad").put("at", now - 1_000))
        gateway.send = BackgroundResult.Refused(409, "interaction_not_pending", "No longer answerable")
        val c = controller()
        c.check()
        c.select("c2")
        c.send()

        assertEquals(OverlayState.AnsweredElsewhere("iPad", now - 1_000, "Rerun only the failures?", "Check nightly test"), effects.states.last())
        assertNull(uncertain.commandOf(question.key))
    }

    @Test fun anAnswerThatCouldNotGoOutIsOfflineAndCanBeSentAgain() {
        gateway.reads += compact()
        gateway.send = BackgroundResult.Unreachable(IOException("Keystore busy"))
        val c = controller()
        c.check()
        c.select("c1")
        c.send()
        assertEquals(OverlayState.Offline(run = false), effects.states.last())
        assertNull(uncertain.commandOf(question.key))

        gateway.reads += compact()
        gateway.send = BackgroundResult.Done(null)
        c.check()
        c.select("c1")
        c.send()
        assertEquals(listOf("answer s1 q1 command-1", "answer s1 q1 command-2"), gateway.calls.filter { it.startsWith("answer") })
    }

    // ---- pushes about the item ----------------------------------------------------------

    @Test fun aRecheckAfterOurOwnSendLeavesSentAndItsAutoClose() {
        gateway.reads += compact()
        val c = controller()
        c.check()
        c.select("c1")
        c.send()
        assertEquals(OverlayState.Sent(null), effects.states.last())
        val calls = gateway.calls.size
        // interaction_answered for our own answer.
        gateway.reads += compact(state = "answered", answeredBy = JSONObject().put("deviceName", "Pixel").put("at", now))
        c.recheck()
        assertEquals(OverlayState.Sent(null), effects.states.last())
        assertEquals(calls, gateway.calls.size)
        timers.single().second.run()
        assertEquals(1, effects.closed)
    }

    @Test fun aRecheckInAnEndStateDoesNothing() {
        gateway.reads += compact(state = "expired")
        val c = controller()
        c.check()
        val calls = gateway.calls.size
        c.recheck()
        assertEquals(calls, gateway.calls.size)
        assertTrue(effects.states.last() is OverlayState.Expired)
    }

    @Test fun aRefreshKeepsTheSelectedChoiceWithoutGoingBackToChecking() {
        gateway.reads += compact()
        val c = controller()
        c.check()
        c.select("c2")
        val shown = effects.states.size
        c.recheck()
        assertEquals("c2", ready.selected)
        assertFalse(effects.states.drop(shown).any { it is OverlayState.Checking })
        // A refresh whose choices no longer offer it drops the selection.
        gateway.reads += compact(choices = 1)
        c.recheck()
        assertNull(ready.selected)
    }

    @Test fun oldUncertainMarksArePruned() {
        val old = UncertainSends(prefs) { now - UncertainSends.MAX_AGE - 1 }
        old.mark("question:old", "command-old")
        val fresh = UncertainSends(prefs) { now }
        fresh.mark("question:new", "command-new")
        fresh.prune()
        assertNull(fresh.commandOf("question:old"))
        assertEquals("command-new", fresh.commandOf("question:new"))
    }

    // ---- other states -----------------------------------------------------------------

    @Test fun answeredElsewhereShowsWhoAndWhen() {
        gateway.reads += compact(state = "answered", answeredBy = JSONObject().put("deviceName", "iPad").put("at", 77L))
        controller().check()
        assertEquals(OverlayState.AnsweredElsewhere("iPad", 77L, "Rerun only the failures?", "Check nightly test"), effects.states.last())
    }

    @Test fun expiredStaleAndGoneQuestionsAreExpired() {
        gateway.reads += compact(state = "expired")
        gateway.reads += compact(epoch = "4")
        gateway.reads += compact(expiresAt = now - 1)
        gateway.reads += BackgroundResult.Refused(404, "not_found", "Gone")
        val c = controller()
        repeat(4) {
            c.check()
            assertTrue("read $it", effects.states.last() is OverlayState.Expired)
        }
    }

    @Test fun aReadyQuestionExpiresOnScreen() {
        gateway.reads += compact(expiresAt = now + 60_000)
        controller().check()
        val (delay, task) = timers.single()
        assertEquals(60_000L, delay)
        task.run()
        assertEquals(OverlayState.Expired("Rerun only the failures?", "Check nightly test"), effects.states.last())
    }

    @Test fun anUnreadableStateIsOfflineAndRetryReadsAgain() {
        gateway.reads += BackgroundResult.Unreachable(IOException("offline"))
        gateway.reads += BackgroundResult.Refused(502, "node_offline", "Offline")
        gateway.reads += compact()
        val c = controller()
        c.check()
        assertEquals(OverlayState.Offline(run = false), effects.states.last())
        c.check()
        assertEquals(OverlayState.Offline(run = false), effects.states.last())
        c.check()
        assertTrue(effects.states.last() is OverlayState.Question)
    }

    @Test fun anEndedPairingClosesTheOverlay() {
        gateway.reads += BackgroundResult.Refused(401, "unauthorized", "Pair again")
        controller().check()
        assertEquals(1, effects.closed)
        assertFalse(effects.states.any { it == OverlayState.Closing })
    }

    @Test fun lateResultsAfterCloseAreDropped() {
        val pending = mutableListOf<Runnable>()
        val c = controller(io = Executor { pending += it })
        c.check()
        c.dispose()
        gateway.reads += compact()
        pending.single().run()
        assertEquals(listOf<OverlayState>(OverlayState.Checking(run = false)), effects.states)
    }

    // ---- missed runs ------------------------------------------------------------------

    @Test fun aMissedRunShowsTheScheduleTimeAndReason() {
        gateway.runReads += missed()
        controller(run).check()
        assertEquals(OverlayState.Checking(run = true), effects.states.first())
        assertEquals(OverlayState.Run("Morning tests", now - 41 * 60_000, "The node was not running."), effects.states.last())
    }

    @Test fun runNowReadsTheRunAgainThenAllowsItWithACommandId() {
        gateway.runReads += missed()
        gateway.runReads += missed()
        val c = controller(run)
        c.check()
        c.decide(RunAction.RUN)

        assertEquals(listOf("run sc1 r1", "run sc1 r1", "allowRun sc1 r1 command-1"), gateway.calls)
        assertEquals(OverlayState.Sent(RunAction.RUN), effects.states.last())
        assertEquals(listOf("tag-r"), effects.removed)
        assertNull(uncertain.commandOf(run.key))
    }

    @Test fun skipReadsTheRunAgainThenDismissesIt() {
        gateway.runReads += missed()
        gateway.runReads += missed()
        val c = controller(run)
        c.check()
        c.decide(RunAction.SKIP)

        assertEquals(listOf("run sc1 r1", "run sc1 r1", "dismissRun sc1 r1 command-1"), gateway.calls)
        assertEquals(OverlayState.Sent(RunAction.SKIP), effects.states.last())
    }

    @Test fun aRunNoLongerMissedSendsNothingAndShowsItsState() {
        gateway.runReads += missed()
        gateway.runReads += missed("running")
        val c = controller(run)
        c.check()
        c.decide(RunAction.RUN)

        assertEquals(listOf("run sc1 r1", "run sc1 r1"), gateway.calls)
        assertEquals(OverlayState.RunSettled("running"), effects.states.last())

    }

    @Test fun aRunThatWasNeverMissedOnScreenClosesTheOverlay() {
        // A failed or finished run without a session has the same push target; only a
        // missed one opens the overlay (default E). Its notification stays.
        for (state in listOf("failed", "completed", "dismissed")) {
            gateway.runReads += missed(state)
            controller(run).check()
        }
        gateway.runReads += BackgroundResult.Refused(404, "not_found", "No run")
        controller(run).check()
        assertEquals(4, effects.closed)
        assertTrue(effects.states.all { it is OverlayState.Checking })
        assertEquals(emptyList<String>(), effects.removed)
    }

    @Test fun aRunDecisionWithAnUnknownOutcomeIsNeverSentAgain() {
        gateway.runReads += missed()
        gateway.runReads += missed()
        gateway.send = BackgroundResult.NotSure("command-1", null)
        val c = controller(run)
        c.check()
        c.decide(RunAction.RUN)
        assertEquals(OverlayState.NotSure(run = true), effects.states.last())

        gateway.runReads += missed()
        val again = controller(run)
        again.check()
        assertEquals(OverlayState.NotSure(run = true), effects.states.last())
        again.decide(RunAction.SKIP)
        assertEquals(1, gateway.calls.count { it.startsWith("allowRun") || it.startsWith("dismissRun") })
        prefs.edit().clear().commit()
    }

    @Test fun theTopRightOpensTheSameTargetAsTheNotification() {
        gateway.runReads += missed()
        val c = controller(run)
        c.check()
        c.openConversation()
        assertEquals(listOf(OpenTarget.run("sc1", "r1")), effects.opened)
    }
}
