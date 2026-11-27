package org.mozufu.pirc.notifications

import java.io.IOException
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mozufu.pirc.background.BackgroundResult
import org.robolectric.RobolectricTestRunner

/** Each push kind: shown, updated, removed, and what happens when the state cannot be read. */
@RunWith(RobolectricTestRunner::class)
class PushReceiptTest {
    private val now = 1_000_000L
    private val tag = PushNote.questionTag("s1", "3", "q1")

    private class Reads : CompactReads {
        var interaction: BackgroundResult = BackgroundResult.Unreachable(IOException("offline"))
        var run: BackgroundResult = BackgroundResult.Unreachable(IOException("offline"))
        val asked = mutableListOf<String>()

        override fun interaction(sessionId: String, interactionId: String): BackgroundResult {
            asked += "interaction $sessionId $interactionId"
            return interaction
        }

        override fun scheduleRun(scheduleId: String, runId: String): BackgroundResult {
            asked += "run $scheduleId $runId"
            return run
        }
    }

    private val reads = Reads()
    private var shown = emptySet<String>()
    private val titles = mutableMapOf<String, String>()
    private val receipt = PushReceipt(reads, { shown }, { now }, { titles[it] })

    private fun note(json: String) = PushNote.parse(json.toByteArray())!!

    private fun question(extra: String = "") = note(
        """{"title":"Build is waiting for you","body":"Run only the failed cases?","tag":"$tag",
           "target":{"sessionId":"s1"},"at":1,"category":"needs_you","lockScreen":"title",
           "kind":"interaction_created","sessionId":"s1","interactionId":"q1","interactionEpoch":"3",
           "expiresAt":${now + 60_000},
           "choices":[{"id":"payload","label":"From the payload"}]$extra}""",
    )

    private fun compact(state: String, epoch: String = "3", choices: Int = 2, expiresAt: Long? = now + 60_000, other: Boolean = false) =
        BackgroundResult.Done(
            JSONObject()
                .put("id", "q1")
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
                .put("controlHolder", JSONObject.NULL)
                .put(
                    "answeredBy",
                    if (state == "answered") JSONObject().put("deviceName", "iPad").put("at", now) else JSONObject.NULL,
                ),
        )

    private fun only(steps: List<ReceiptStep>): ReceiptStep {
        assertEquals(1, steps.size)
        return steps.single()
    }

    private fun shownSpec(steps: List<ReceiptStep>) = (only(steps) as ReceiptStep.Show).spec

    @Test fun anOpenQuestionShowsTheChoicesOfTheCompactRead() {
        reads.interaction = compact("pending")
        val spec = shownSpec(receipt.plan(question()))
        assertEquals(listOf("interaction s1 q1"), reads.asked)
        assertEquals(tag, spec.tag)
        assertEquals(NotificationChannels.NEEDS_YOU, spec.channel)
        assertEquals("Build is waiting for you", spec.title)
        // The question as the Gateway reads it now, not the payload's text.
        assertEquals("Rerun only the failures?", spec.body)
        assertEquals(listOf("Choice 1", "Choice 2"), spec.choices.map { it.label })
        // Never the payload's own choices.
        assertTrue(spec.choices.none { it.label == "From the payload" })
        assertEquals(
            mapOf("type" to "question", "sessionId" to "s1", "interactionId" to "q1", "epoch" to "3", "choice" to "c2", "label" to "Choice 2"),
            spec.choices[1].open.fields,
        )
        // Collapsed: "Answer…" and "Open conversation"; neither answers.
        assertEquals(listOf(ActionLabel.ANSWER, ActionLabel.OPEN_CONVERSATION), spec.actions.map { it.label })
        assertEquals("question", spec.actions[0].open.fields["type"])
        assertNull(spec.actions[0].open.fields["choice"])
        assertEquals(mapOf("type" to "session", "sessionId" to "s1"), spec.actions[1].open.fields)
        assertEquals("question", spec.open.fields["type"])
        // Gone with the question: its choices never outlive it.
        assertEquals(60_000L, spec.timeoutMillis)
    }

    @Test fun jsonNullsAreNotText() {
        reads.interaction = BackgroundResult.Done(
            (compact("pending") as BackgroundResult.Done).body!!
                .put("question", JSONObject().put("title", JSONObject.NULL)),
        )
        val spec = shownSpec(receipt.plan(question()))
        assertEquals("Run only the failed cases?", spec.body)
        val untitled = note(
            """{"title":null,"body":null,"tag":"thread:t1","target":{"potId":"p","threadId":"t1"},"at":1,"category":"done"}""",
        )
        assertEquals("", untitled.title)
        assertEquals("", untitled.body)
        shown = setOf(tag)
        reads.interaction = BackgroundResult.Done(
            (compact("answered") as BackgroundResult.Done).body!!
                .put("answeredBy", JSONObject().put("deviceName", JSONObject.NULL).put("at", now)),
        )
        assertEquals("", shownSpec(receipt.plan(answered())).answeredOn)
    }

    @Test fun aQuestionAlreadyPastItsExpiryIsNotPosted() {
        val expired = note(
            """{"title":"T","body":"B","tag":"$tag","target":{"sessionId":"s1"},"at":1,"category":"needs_you",
               "kind":"interaction_created","sessionId":"s1","interactionId":"q1","interactionEpoch":"3",
               "expiresAt":${now - 1}}""",
        )
        reads.interaction = BackgroundResult.Unreachable(IOException("offline"))
        assertEquals(listOf(ReceiptStep.Remove(tag)), receipt.plan(expired))
        // A compact read without its own expiry uses the push's.
        reads.interaction = compact("pending", expiresAt = null)
        assertEquals(listOf(ReceiptStep.Remove(tag)), receipt.plan(expired))
    }

    @Test fun aQuestionKeepsItsSessionNameForTheTitle() {
        reads.interaction = compact("pending")
        assertEquals("Build", shownSpec(receipt.plan(question(""","sessionName":"Build""""))).waitingSession)
        assertNull(shownSpec(receipt.plan(question())).waitingSession)
    }

    @Test fun otherIsNotCountedAndTakesASlotOnlyWhenOneIsLeft() {
        reads.interaction = compact("pending", choices = 3, other = true)
        assertEquals(listOf("Choice 1", "Choice 2", "Choice 3"), shownSpec(receipt.plan(question())).choices.map { it.label })
        reads.interaction = compact("pending", choices = 2, other = true)
        assertEquals(listOf("Choice 1", "Choice 2", "Other"), shownSpec(receipt.plan(question())).choices.map { it.label })
        reads.interaction = compact("pending", choices = 4, other = true)
        assertTrue(shownSpec(receipt.plan(question())).choices.isEmpty())
    }

    @Test fun moreThanThreeOptionsGiveNoChoices() {
        reads.interaction = compact("pending", choices = 4)
        assertTrue(shownSpec(receipt.plan(question())).choices.isEmpty())
    }

    @Test fun aQuestionWhoseStateCannotBeReadShowsNoChoices() {
        reads.interaction = BackgroundResult.Unreachable(IOException("offline"))
        val spec = shownSpec(receipt.plan(question()))
        assertTrue(spec.choices.isEmpty())
        assertEquals("Run only the failed cases?", spec.body)
        assertEquals(listOf(ActionLabel.ANSWER, ActionLabel.OPEN_CONVERSATION), spec.actions.map { it.label })

        reads.interaction = BackgroundResult.Refused(502, null, null)
        assertTrue(shownSpec(receipt.plan(question())).choices.isEmpty())
    }

    @Test fun aQuestionThatEndedIsRemoved() {
        for (state in listOf("answered", "expired")) {
            reads.interaction = compact(state)
            assertEquals(ReceiptStep.Remove(tag), only(receipt.plan(question())))
        }
        // Another runner epoch, or past its expiry, is not this question any more.
        reads.interaction = compact("pending", epoch = "4")
        assertEquals(ReceiptStep.Remove(tag), only(receipt.plan(question())))
        reads.interaction = compact("pending", expiresAt = now - 1)
        assertEquals(ReceiptStep.Remove(tag), only(receipt.plan(question())))
        reads.interaction = BackgroundResult.Refused(404, "not_found", null)
        assertEquals(ReceiptStep.Remove(tag), only(receipt.plan(question())))
    }

    @Test fun anUnpairedDeviceShowsNothing() {
        reads.interaction = BackgroundResult.Unpaired
        assertTrue(receipt.plan(question()).isEmpty())
        // A refused token: only "Pairing ended" (shown once by the renderer).
        reads.interaction = BackgroundResult.Refused(401, "unauthenticated", null)
        assertEquals(listOf(ReceiptStep.PairingEnded), receipt.plan(question()))
        reads.run = BackgroundResult.Refused(401, "unauthenticated", null)
        assertEquals(listOf(ReceiptStep.PairingEnded), receipt.plan(missed()))
    }

    @Test fun aForbiddenReadShowsThePushTextWithoutChoices() {
        reads.interaction = BackgroundResult.Refused(403, "forbidden", null)
        val spec = shownSpec(receipt.plan(question()))
        assertTrue(spec.choices.isEmpty())
        assertEquals("Run only the failed cases?", spec.body)
        reads.run = BackgroundResult.Refused(403, "forbidden", null)
        assertTrue(shownSpec(receipt.plan(missed())).actions.isEmpty())
    }

    private fun answered() = note(
        """{"title":"","body":"","tag":"$tag","target":{"sessionId":"s1"},"at":2,"category":"needs_you",
           "lockScreen":"full","kind":"interaction_answered","sessionId":"s1","interactionId":"q1",
           "interactionEpoch":"3","answeredBy":{"deviceName":"Payload device","at":2}}""",
    )

    @Test fun anAnswerElsewhereUpdatesTheNotificationThenRemovesIt() {
        shown = setOf(tag)
        titles[tag] = "Build is waiting for you"
        reads.interaction = compact("answered")
        val spec = shownSpec(receipt.plan(answered()))
        assertEquals(tag, spec.tag)
        // Who answered comes from the compact read.
        assertEquals("iPad", spec.answeredOn)
        // The notification's own title, never the question (the lock screen shows titles).
        assertEquals("Build is waiting for you", spec.title)
        assertEquals(PushReceipt.ANSWERED_TIMEOUT, spec.timeoutMillis)
        assertTrue(spec.actions.isEmpty())
        assertTrue(spec.choices.isEmpty())
        assertTrue(spec.silent)
        assertEquals("full", spec.lockScreen)
        // Without a title on screen: the push's, which is empty (the renderer shows "pirc").
        titles.clear()
        assertEquals("", shownSpec(receipt.plan(answered())).title)
    }

    @Test fun anAnswerThatCannotBeConfirmedOnlyRemovesTheButtons() {
        shown = setOf(tag)
        reads.interaction = BackgroundResult.Unreachable(IOException("offline"))
        assertEquals(ReceiptStep.Remove(tag), only(receipt.plan(answered())))
        reads.interaction = compact("expired")
        assertEquals(ReceiptStep.Remove(tag), only(receipt.plan(answered())))
    }

    @Test fun anAnswerForANotificationNotShownDoesNothing() {
        reads.interaction = compact("answered")
        assertTrue(receipt.plan(answered()).isEmpty())
        assertTrue(reads.asked.isEmpty())
    }

    @Test fun aRefreshRemovesTheSessionsQuestionsThatEnded() {
        val other = PushNote.questionTag("s1", "3", "q2")
        val elsewhere = PushNote.questionTag("s2", "3", "q9")
        shown = setOf(tag, other, elsewhere, "calendar:e1:x")
        val refresh = note(
            """{"title":"","body":"","tag":"session:s1","target":{"sessionId":"s1"},"at":3,
               "category":"needs_you","lockScreen":"title","kind":"interaction_refresh","sessionId":"s1"}""",
        )
        val states = mapOf("q1" to compact("pending"), "q2" to compact("answered"))
        val reader = object : CompactReads {
            override fun interaction(sessionId: String, interactionId: String) = states.getValue(interactionId)

            override fun scheduleRun(scheduleId: String, runId: String) = error("not read")
        }
        val steps = PushReceipt(reader, { shown }, { now }).plan(refresh)
        assertEquals(listOf(ReceiptStep.Remove(other)), steps)
    }

    private fun missed() = note(
        """{"title":"Nightly tests was missed","body":"Allow it to run it now, or dismiss it.","tag":"run:r1",
           "target":{"schedules":true,"scheduleId":"sch1","runId":"r1"},"at":4,"category":"needs_you",
           "lockScreen":"title","silent":true}""",
    )

    private fun run(state: String) = BackgroundResult.Done(
        JSONObject().put("run", JSONObject().put("id", "r1").put("scheduleId", "sch1").put("state", state)),
    )

    @Test fun aMissedRunOffersViewAndRunAndSkip() {
        reads.run = run("missed")
        val spec = shownSpec(receipt.plan(missed()))
        assertEquals(listOf("run sch1 r1"), reads.asked)
        assertEquals(NotificationChannels.NEEDS_YOU, spec.channel)
        assertTrue(spec.silent)
        assertEquals(listOf(ActionLabel.VIEW_AND_RUN, ActionLabel.SKIP), spec.actions.map { it.label })
        assertEquals("view", spec.actions[0].open.fields["action"])
        assertEquals("skip", spec.actions[1].open.fields["action"])
        assertEquals("r1", spec.open.fields["runId"])
    }

    @Test fun aMissedRunThatWasHandledIsRemoved() {
        for (state in listOf("running", "dismissed", "skipped", "completed")) {
            reads.run = run(state)
            assertEquals(state, ReceiptStep.Remove("run:r1"), only(receipt.plan(missed())))
        }
    }

    @Test fun aRunWhoseStateCannotBeReadHasNoButtons() {
        reads.run = BackgroundResult.Unreachable(IOException("offline"))
        val spec = shownSpec(receipt.plan(missed()))
        assertTrue(spec.actions.isEmpty())
        assertEquals("Nightly tests was missed", spec.title)
    }

    @Test fun aCompletedScheduleIsDone() {
        val done = note(
            """{"title":"Nightly tests finished","body":"Scheduled run: open it to read the result.",
               "tag":"session:s9","target":{"sessionId":"s9"},"at":5,"category":"done","lockScreen":"title"}""",
        )
        val spec = shownSpec(receipt.plan(done))
        assertEquals(NotificationChannels.DONE, spec.channel)
        assertEquals(mapOf("type" to "session", "sessionId" to "s9"), spec.open.fields)
        assertTrue(reads.asked.isEmpty())
        // A finished run without a session is read, and shown while the read agrees.
        reads.run = run("completed")
        val noSession = note(
            """{"title":"Nightly tests finished","body":"b","tag":"run:r2",
               "target":{"schedules":true,"scheduleId":"sch1","runId":"r2"},"at":5,"category":"done"}""",
        )
        assertEquals(NotificationChannels.DONE, shownSpec(receipt.plan(noSession)).channel)
    }

    @Test fun calendarPotTargetsSummaryAndTestOpenTheirTargets() {
        fun push(target: String, category: String?, tag: String = "t") = note(
            """{"title":"T","body":"B","tag":"$tag","target":$target,"at":6
               ${category?.let { ",\"category\":\"$it\"" } ?: ""}}""",
        )
        val cases = listOf(
            Triple(push("""{"calendar":true,"eventId":"e1","occurrenceStart":"2026-11-27T09:00"}""", "calendar"), NotificationChannels.CALENDAR,
                mapOf("type" to "calendar", "eventId" to "e1", "occurrenceStart" to "2026-11-27T09:00")),
            Triple(push("""{"approvalId":"a1"}""", "needs_you"), NotificationChannels.NEEDS_YOU, mapOf("type" to "approval", "approvalId" to "a1")),
            Triple(push("""{"budgetRequestId":"b1"}""", "needs_you"), NotificationChannels.NEEDS_YOU, mapOf("type" to "budget", "budgetRequestId" to "b1")),
            Triple(push("""{"potId":"p1","threadId":"t1"}""", "done"), NotificationChannels.DONE, mapOf("type" to "thread", "potId" to "p1", "threadId" to "t1")),
            Triple(push("""{"potId":"p1","threadId":"t1"}""", "progress"), NotificationChannels.PROGRESS, mapOf("type" to "thread", "potId" to "p1", "threadId" to "t1")),
            Triple(push("""{"activityNotificationId":"n1"}""", "done"), NotificationChannels.DONE, mapOf("type" to "activityNotification", "activityNotificationId" to "n1")),
            Triple(push("""{"activity":true,"summary":{"count":2,"categories":{"done":2}}}""", null, "summary"), NotificationChannels.SUMMARY, mapOf("type" to "activity")),
            Triple(push("""{"schedules":true}""", null, "test"), NotificationChannels.SUMMARY, mapOf("type" to "settings")),
        )
        for ((push, channel, open) in cases) {
            val spec = shownSpec(receipt.plan(push))
            assertEquals(push.kind.toString(), channel, spec.channel)
            assertEquals(open, spec.open.fields)
            assertTrue(spec.actions.isEmpty())
            assertTrue(spec.choices.isEmpty())
        }
        assertTrue(reads.asked.isEmpty())
    }
}
