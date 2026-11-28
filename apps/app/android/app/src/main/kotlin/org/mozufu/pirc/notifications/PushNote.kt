package org.mozufu.pirc.notifications

import java.nio.charset.StandardCharsets
import org.json.JSONObject
import org.mozufu.pirc.background.long
import org.mozufu.pirc.background.text

/** What a push is about, read from its payload (`docs/development/gateway-and-node.md`, Push). */
sealed interface PushKind {
    /** `interaction_created`: an agent question. */
    data class Question(val sessionId: String, val interactionId: String, val epoch: String) : PushKind

    /** `interaction_answered`: a question was answered, perhaps on another device. */
    data class Answered(val sessionId: String, val interactionId: String, val epoch: String) : PushKind

    /** `interaction_refresh`: something about a session's questions changed; no ID given. */
    data class Refresh(val sessionId: String) : PushKind

    /** A scheduled run named by `{schedules, scheduleId, runId}`: missed, or ended without a session. */
    data class Run(val scheduleId: String, val runId: String) : PushKind

    /** A session to open: a run that failed or waits, or a finished run. */
    data class Session(val sessionId: String) : PushKind

    data object Schedules : PushKind

    data class Calendar(val eventId: String?, val occurrenceStart: String?) : PushKind

    /** A pot asks to use a model (E25). */
    data class Approval(val approvalId: String) : PushKind

    data class BudgetRequest(val budgetRequestId: String) : PushKind

    /** A pot's reply, a handover or opened work. */
    data class PotThread(val potId: String, val threadId: String) : PushKind

    /** An observation notification. */
    data class ActivityNotification(val id: String) : PushKind

    /** The digest (`tag: "summary"`). */
    data object Summary : PushKind

    /** `POST /api/push/test`. */
    data object Test : PushKind

    /** A target this app does not know; it only opens the app. */
    data object Other : PushKind
}

/**
 * A push's words for this app's language: a key of `crates/pirc-gateway/src/push/text.rs`
 * and the names that go into them ([KnownText.pushTitle]). The digest's comes from its
 * count (`target.summary.count`).
 */
data class PushText(val key: String, val args: Map<String, String>)

/** One decrypted push. It holds no secret and no answer; the app reads the state first. */
data class PushNote(
    val title: String,
    val body: String,
    /** Notifications with the same tag replace each other; also the Android tag. */
    val tag: String,
    /** `needs_you`, `done`, `progress` or `calendar`; null for the summary and the test. */
    val category: String?,
    /** `hidden`, `title` (the default) or `full`. */
    val lockScreen: String,
    /** Sent during quiet hours: no sound, no vibration. */
    val silent: Boolean,
    val at: Long,
    val kind: PushKind,
    /** When a question stops taking answers, from the payload. */
    val expiresAt: Long? = null,
    /** The session's name on a question, so the title is worded here. */
    val sessionName: String? = null,
    /** The words for this app's language; null shows the title and body as sent. */
    val text: PushText? = null,
) {
    companion object {
        /** Null for anything that is not a push of this Gateway's shape. */
        fun parse(content: ByteArray): PushNote? {
            val json = runCatching { JSONObject(String(content, StandardCharsets.UTF_8)) }.getOrNull() ?: return null
            val tag = json.text("tag") ?: ""
            val target = json.optJSONObject("target") ?: JSONObject()
            val kind = kindOf(json, tag, target) ?: return null
            return PushNote(
                title = json.text("title") ?: "",
                body = json.text("body") ?: "",
                tag = tag.ifEmpty { "pirc:${json.long("at") ?: 0}" },
                category = json.text("category")?.takeIf { it in CATEGORIES },
                lockScreen = json.text("lockScreen")?.takeIf { it in LOCK_SCREENS } ?: "title",
                silent = json.optBoolean("silent", false),
                at = json.long("at") ?: 0,
                kind = kind,
                expiresAt = json.long("expiresAt"),
                sessionName = json.text("sessionName"),
                text = textOf(json, kind, target),
            )
        }

        private fun textOf(json: JSONObject, kind: PushKind, target: JSONObject): PushText? {
            if (kind is PushKind.Summary) {
                val count = target.optJSONObject("summary")?.long("count") ?: return null
                return PushText(SUMMARY_KEY, mapOf("count" to count.toString()))
            }
            val text = json.optJSONObject("text") ?: return null
            val key = text.text("key") ?: return null
            val args = text.optJSONObject("args") ?: JSONObject()
            val names = args.keys().asSequence().mapNotNull { name -> (args.opt(name) as? String)?.let { name to it } }
            return PushText(key, names.toMap())
        }

        /** Not a Gateway key: the digest's title from its count. */
        const val SUMMARY_KEY = "summary"

        private val CATEGORIES = setOf("needs_you", "done", "progress", "calendar")
        private val LOCK_SCREENS = setOf("hidden", "title", "full")

        private fun kindOf(json: JSONObject, tag: String, target: JSONObject): PushKind? {
            val session = json.text("sessionId")
            val interaction = json.text("interactionId")
            val epoch = json.text("interactionEpoch")
            when (json.text("kind")) {
                "interaction_created" -> {
                    if (session == null || interaction == null || epoch == null) return null
                    // The tag names this exact question; a payload that disagrees is not trusted.
                    if (tag != questionTag(session, epoch, interaction)) return null
                    return PushKind.Question(session, interaction, epoch)
                }
                "interaction_answered" -> {
                    if (session == null || interaction == null || epoch == null) return null
                    if (tag != questionTag(session, epoch, interaction)) return null
                    return PushKind.Answered(session, interaction, epoch)
                }
                "interaction_refresh" -> return session?.let { PushKind.Refresh(it) }
            }
            target.text("approvalId")?.let { return PushKind.Approval(it) }
            target.text("budgetRequestId")?.let { return PushKind.BudgetRequest(it) }
            target.text("activityNotificationId")?.let { return PushKind.ActivityNotification(it) }
            val pot = target.text("potId")
            val thread = target.text("threadId")
            if (pot != null && thread != null) return PushKind.PotThread(pot, thread)
            if (tag == "summary" || target.optBoolean("activity", false)) return PushKind.Summary
            if (tag == "test") return PushKind.Test
            if (target.optBoolean("calendar", false)) {
                return PushKind.Calendar(target.text("eventId"), target.text("occurrenceStart"))
            }
            if (target.optBoolean("schedules", false)) {
                val schedule = target.text("scheduleId")
                val run = target.text("runId")
                return if (schedule != null && run != null) PushKind.Run(schedule, run) else PushKind.Schedules
            }
            target.text("sessionId")?.let { return PushKind.Session(it) }
            return PushKind.Other
        }

        /** The Gateway's question tag: `interaction:<hex session>:<epoch>:<hex interaction>`. */
        fun questionTag(sessionId: String, epoch: String, interactionId: String) =
            "interaction:${hex(sessionId)}:$epoch:${hex(interactionId)}"

        /** The session, epoch and interaction of a question tag, or null. */
        fun parseQuestionTag(tag: String): Triple<String, String, String>? {
            val parts = tag.split(':')
            if (parts.size != 4 || parts[0] != "interaction") return null
            val session = unhex(parts[1]) ?: return null
            val interaction = unhex(parts[3]) ?: return null
            if (parts[2].isEmpty()) return null
            return Triple(session, parts[2], interaction)
        }

        private fun hex(text: String) = text.toByteArray(StandardCharsets.UTF_8).joinToString("") { "%02x".format(it) }

        private fun unhex(text: String): String? {
            if (text.isEmpty() || text.length % 2 != 0) return null
            val bytes = ByteArray(text.length / 2)
            for (i in bytes.indices) {
                bytes[i] = text.substring(i * 2, i * 2 + 2).toIntOrNull(16)?.toByte() ?: return null
            }
            return String(bytes, StandardCharsets.UTF_8)
        }
    }
}
