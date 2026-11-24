package dev.pirc.pirc_mobile

import org.junit.Assert.*
import org.junit.Test

class ReplyRulesTest {
    @Test fun duplicateCannotOverwriteAcceptedAnswer() {
        val accepted = ReplyRules.answer(ReplyState(), 1, ReplyRules.choices[0], "pending", "now")
        val duplicate = ReplyRules.answer(accepted.state, 1, ReplyRules.choices[1], "pending", "later")
        assertEquals("REJECTED", duplicate.error)
        assertEquals(accepted.state, duplicate.state)
    }
    @Test fun staleRevisionAndInvalidChoiceCannotWrite() {
        val original = ReplyState(revision = 3)
        for ((revision, choice) in listOf(2L to ReplyRules.choices[0], 3L to "bad")) {
            val result = ReplyRules.answer(original, revision, choice, "pending", "now")
            assertEquals("REJECTED", result.error)
            assertEquals(original, result.state)
        }
    }
    @Test fun unavailableStatesCannotAnswer() {
        for (status in listOf("expired", "controlledElsewhere", "offline", "handled")) {
            val state = ReplyState(status = status)
            val result = ReplyRules.answer(state, 1, ReplyRules.choices[0], "pending", "now")
            assertEquals("REJECTED", result.error)
            assertEquals(state, result.state)
        }
    }
    @Test fun racingDeviceWinsWithoutOverwritingIt() {
        val result = ReplyRules.answer(ReplyState(), 1, ReplyRules.choices[0], "race", "now")
        assertEquals("REJECTED", result.error)
        assertEquals("桌面（模擬）", result.state.actor)
        assertEquals(ReplyRules.choices[1], result.state.answer)
    }
    @Test fun lostResponseStillCommitsOnce() {
        val result = ReplyRules.answer(ReplyState(), 1, ReplyRules.choices[0], "unknown", "now")
        assertEquals("OUTCOME_UNKNOWN", result.error)
        assertEquals("handled", result.state.status)
        assertEquals(2L, result.state.revision)
    }
}
