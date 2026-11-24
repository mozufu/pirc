package dev.pirc.pirc_mobile

data class ReplyState(
    val revision: Long = 1,
    val status: String = "pending",
    val answer: String? = null,
    val actor: String? = null,
    val answeredAt: String? = null,
)

data class AnswerResult(val state: ReplyState, val error: String? = null)

/** Pure fixture transition. Production must replace this with gateway validation. */
object ReplyRules {
    val choices = listOf("先驗證浮窗", "先看完整對話")

    fun answer(state: ReplyState, revision: Long, choice: String, scenario: String, now: String): AnswerResult {
        if (state.status != "pending" || state.revision != revision || choice !in choices) {
            return AnswerResult(state, "REJECTED")
        }
        if (scenario == "race") {
            return AnswerResult(ReplyState(state.revision + 1, "handled", choices[1], "桌面（模擬）", now), "REJECTED")
        }
        val next = ReplyState(state.revision + 1, "handled", choice, "此裝置", now)
        return AnswerResult(next, if (scenario == "unknown") "OUTCOME_UNKNOWN" else null)
    }
}
