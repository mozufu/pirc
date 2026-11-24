package dev.pirc.pirc_mobile

import android.content.Context
import java.time.OffsetDateTime

class FixtureFailure(val code: String) : Exception(code)

/** Activity and overlay share one process and this persisted local fixture. */
class FixtureStore(context: Context) {
    private val prefs = context.getSharedPreferences("mobile_validation", Context.MODE_PRIVATE)
    fun state() = ReplyState(
        prefs.getLong("revision", 1), prefs.getString("status", "pending")!!,
        prefs.getString("answer", null), prefs.getString("actor", null), prefs.getString("answeredAt", null),
    )

    fun snapshot(): Map<String, Any?> {
        val state = state()
        return mapOf(
            "sessionId" to SESSION, "interactionId" to "question-1",
            "revision" to state.revision, "status" to state.status, "answer" to state.answer,
            "actor" to state.actor, "answeredAt" to state.answeredAt,
            "latestVersion" to prefs.getInt("latestVersion", 1), "draft" to prefs.getString("draft", ""),
        )
    }

    fun configure(scenario: String) = synchronized(lock) {
        require(scenario in setOf("pending", "handled", "expired", "controlledElsewhere", "offline", "race", "unknown"))
        val status = if (scenario == "race" || scenario == "unknown") "pending" else scenario
        val state = ReplyState(state().revision + 1, status,
            if (status == "handled") ReplyRules.choices[1] else null,
            if (status == "handled") "桌面（模擬）" else null,
            if (status == "handled") OffsetDateTime.now().toString() else null)
        save(state)
        check(prefs.edit().putString("scenario", scenario).commit())
    }

    fun answer(revision: Long, choice: String): Map<String, Any?> = synchronized(lock) {
        val previous = state()
        val result = ReplyRules.answer(previous, revision, choice,
            prefs.getString("scenario", "pending")!!, OffsetDateTime.now().toString())
        if (result.state != previous) save(result.state)
        result.error?.let { throw FixtureFailure(it) }
        snapshot()
    }

    private fun save(state: ReplyState) {
        check(prefs.edit().putLong("revision", state.revision).putString("status", state.status)
            .putString("answer", state.answer).putString("actor", state.actor)
            .putString("answeredAt", state.answeredAt).commit())
    }
    fun saveDraft(draft: String) { check(prefs.edit().putString("draft", draft).commit()) }
    fun newVersion() { check(prefs.edit().putInt("latestVersion", prefs.getInt("latestVersion", 1) + 1).commit()) }

    companion object {
        const val SESSION = "mobile-validation"
        private val lock = Any()
    }
}
