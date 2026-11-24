package dev.pirc.pirc_mobile

import dev.pirc.android.core.*
import dev.pirc.android.core.timeline.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class GatewayContractTest {
    private val question = Interaction("q", "epoch", "select", "Continue?", expiresAt=1000,
        options=listOf(InteractionOption("a", "A"), InteractionOption("b", "B")))
    private fun state(q: Interaction = question) = SessionState(Session("s", "w", "Session"), "running", null,
        emptyList(), listOf(q), emptyList(), "cursor", "epoch")
    private fun refused(snapshot: SessionState, epoch: String = "epoch", data: Map<String, Any?> = mapOf("values" to listOf("a")), now: Long = 10) {
        try { checkedAnswer(snapshot, "q", epoch, data, now); fail("must reject without posting") }
        catch (e: ApiException) { assertTrue(e.status in 400..499) }
    }
    @Test fun matchingFreshQuestionCanBeAnswered() {
        assertTrue(checkedAnswer(state(), "q", "epoch", mapOf("values" to listOf("a")), 10) is InteractionAnswer.Choices)
    }
    @Test fun runnerEpochMustMatchBothSnapshotAndQuestion() {
        refused(state(), "old")
        refused(state().copy(runnerEpoch="new"))
    }
    @Test fun completedAndExpiredQuestionsCannotBeAnswered() {
        refused(state(question.copy(status="answered")))
        refused(state(), now=1000)
        refused(state().copy(interactions=emptyList()))
    }
    @Test fun selectionMustStillExistAndRespectSingleChoice() {
        refused(state(), data=mapOf("values" to listOf("gone")))
        refused(state(), data=mapOf("values" to listOf("a", "b")))
        refused(state(), data=mapOf("values" to listOf("a", "a")))
    }
    @Test fun cancellationAlsoRequiresFreshQuestion() {
        refused(state(question.copy(status="expired")), data=mapOf("cancelled" to true))
        assertEquals(InteractionAnswer.Cancel, checkedAnswer(state(), "q", "epoch", mapOf("cancelled" to true), 10))
    }
    @Test fun platformWireContainsCodecValuesAndPreservesBooleansAndNumbers() {
        val raw = mapOf("flag" to true, "generation" to 9007199254740992L, "nullable" to null, "nested" to listOf(mapOf("text" to "中文")))
        assertEquals(raw, raw.json().wire())
        val wire = state().wire()
        assertEquals("epoch", wire["runnerEpoch"])
        assertEquals("s", (wire["session"] as Map<*, *>)["id"])
        assertEquals("q", ((wire["interactions"] as List<*>).single() as Map<*, *>)["id"])
    }
}
