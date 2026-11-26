package org.mozufu.pirc.notifications

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class PushNoteTest {
    private fun parse(json: String) = PushNote.parse(json.toByteArray())

    @Test fun questionTagsMatchTheGateways() {
        // crates/pirc-gateway/src/push/interactions.rs: interaction_tag (hex UTF-8).
        assertEquals("interaction:7331:3:7131", PushNote.questionTag("s1", "3", "q1"))
        assertEquals(Triple("s1", "3", "q1"), PushNote.parseQuestionTag("interaction:7331:3:7131"))
        assertEquals(Triple("ä", "0", "x"), PushNote.parseQuestionTag(PushNote.questionTag("ä", "0", "x")))
        assertNull(PushNote.parseQuestionTag("interaction:zz:3:7131"))
        assertNull(PushNote.parseQuestionTag("session:s1"))
    }

    @Test fun readsTheCommonFields() {
        val note = parse(
            """{"title":"T","body":"B","tag":"thread:t1","target":{"potId":"p","threadId":"t1"},"at":9,
               "category":"done","lockScreen":"hidden","silent":true}""",
        )!!
        assertEquals("T", note.title)
        assertEquals("B", note.body)
        assertEquals("thread:t1", note.tag)
        assertEquals("done", note.category)
        assertEquals("hidden", note.lockScreen)
        assertTrue(note.silent)
        assertEquals(9L, note.at)
        assertEquals(PushKind.PotThread("p", "t1"), note.kind)
    }

    @Test fun defaultsWhenFieldsAreMissingOrUnknown() {
        val note = parse("""{"title":"T","body":"B","tag":"test","target":{"schedules":true},"at":1,"lockScreen":"odd","category":"odd"}""")!!
        assertEquals("title", note.lockScreen)
        assertNull(note.category)
        assertFalse(note.silent)
        assertEquals(PushKind.Test, note.kind)
    }

    @Test fun aQuestionWhoseTagDisagreesIsNotTrusted() {
        assertNull(
            parse(
                """{"title":"T","body":"B","tag":"interaction:7332:3:7131","target":{"sessionId":"s1"},"at":1,
                   "kind":"interaction_created","sessionId":"s1","interactionId":"q1","interactionEpoch":"3"}""",
            ),
        )
        assertNull(parse("not json"))
        assertNull(
            parse("""{"tag":"x","kind":"interaction_created","sessionId":"s1","interactionId":"q1"}"""),
        )
    }

    @Test fun eachTargetHasItsKind() {
        fun kind(target: String, tag: String = "t", extra: String = "") =
            parse("""{"title":"T","body":"B","tag":"$tag","target":$target,"at":1$extra}""")!!.kind
        assertEquals(PushKind.Run("s", "r"), kind("""{"schedules":true,"scheduleId":"s","runId":"r"}"""))
        assertEquals(PushKind.Schedules, kind("""{"schedules":true,"scheduleId":"s"}"""))
        assertEquals(PushKind.Session("s1"), kind("""{"sessionId":"s1"}"""))
        assertEquals(PushKind.Calendar("e", "o"), kind("""{"calendar":true,"eventId":"e","occurrenceStart":"o"}"""))
        assertEquals(PushKind.Approval("a"), kind("""{"approvalId":"a"}"""))
        assertEquals(PushKind.BudgetRequest("b"), kind("""{"budgetRequestId":"b"}"""))
        assertEquals(PushKind.ActivityNotification("n"), kind("""{"activityNotificationId":"n"}"""))
        assertEquals(PushKind.Summary, kind("""{"activity":true}""", tag = "summary"))
        assertEquals(PushKind.Other, kind("""{}"""))
        assertEquals(
            PushKind.Refresh("s1"),
            kind("""{"sessionId":"s1"}""", extra = ""","kind":"interaction_refresh","sessionId":"s1""""),
        )
    }
}
