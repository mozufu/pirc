package org.mozufu.pirc.notifications

import android.content.Context
import org.mozufu.pirc.R

/**
 * Fixed English text the Gateway and the agent send, shown in the system language
 * instead. The values mirror `pirc_protocol` (`crates/pirc-protocol/src/lib.rs`);
 * anything else is shown as sent.
 */
object KnownText {
    /** `PLACEHOLDER_SESSION_NAME`: a new session's name until its title replaces it. */
    const val PLACEHOLDER_SESSION_NAME = "New session"

    /** `AUTO_MODE_APPROVAL_TITLE` and `READ_ONLY_APPROVAL_TITLE`. */
    const val AUTO_MODE_APPROVAL_TITLE = "Auto mode: allow a potentially dangerous action?"
    const val READ_ONLY_APPROVAL_TITLE = "Read-only mode: allow this action?"

    /** A session's name for display. */
    fun sessionName(context: Context, name: String): String =
        if (name == PLACEHOLDER_SESSION_NAME) context.getString(R.string.session_untitled) else name

    /** A question's title (or a notification's body made from it) for display. */
    fun questionTitle(context: Context, text: String): String = when (text) {
        AUTO_MODE_APPROVAL_TITLE -> context.getString(R.string.approval_auto_mode_title)
        READ_ONLY_APPROVAL_TITLE -> context.getString(R.string.approval_read_only_title)
        else -> text
    }

    /**
     * An approval question's message for display. The agent writes
     * `<label> (<tool>, in <place>):\n\n<text>\n\nReason: <reason>`
     * (`crates/pirc-agent/src/auto_mode/mod.rs`, `approve`); the frame is shown in the
     * system language, the command and the reason (the classifier's) as sent. Anything
     * else, or a message under another title, is shown as sent.
     */
    fun questionMessage(context: Context, title: String, message: String): String {
        if (title != AUTO_MODE_APPROVAL_TITLE && title != READ_ONLY_APPROVAL_TITLE) return message
        val cut = message.lastIndexOf(REASON_MARK).takeIf { it >= 0 } ?: return message
        val head = message.substring(0, cut)
        val reason = message.substring(cut + REASON_MARK.length)
        val textAt = head.indexOf("):\n\n").takeIf { it >= 0 } ?: return message
        val header = head.substring(0, textAt)
        val text = head.substring(textAt + 4)
        val (label, id) = APPROVAL_LABELS.entries.firstOrNull { header.startsWith("${it.key} (") } ?: return message
        val where = header.substring(label.length + 2)
        val inAt = where.indexOf(", in ").takeIf { it >= 0 } ?: return message
        return context.getString(
            R.string.approval_message,
            context.getString(id),
            where.substring(0, inAt),
            where.substring(inAt + 5),
            text,
            reason,
        )
    }

    private const val REASON_MARK = "\n\nReason: "
    private val APPROVAL_LABELS = mapOf(
        "File change" to R.string.approval_label_file_change,
        "Input" to R.string.approval_label_input,
        "Script" to R.string.approval_label_script,
        "Command" to R.string.approval_label_command,
    )

    /**
     * A push's fixed title or body for display: the English of
     * `crates/pirc-gateway/src/push/text.rs`, or a question's title.
     */
    fun pushFixed(context: Context, text: String): String =
        FIXED[text]?.let { context.getString(it) } ?: questionTitle(context, text)

    private val FIXED = mapOf(
        "It needs your answer to go on." to R.string.push_question_body,
        "A budget limit is used up. Open the thread to review its limits." to R.string.push_pot_budget_blocked_body,
        "Open it to approve or deny." to R.string.push_pot_budget_request_body,
        "Open the thread to review it." to R.string.push_pot_handover_body,
        "Open the thread to read it." to R.string.push_pot_replied_body,
        "A pot noticed something" to R.string.push_pot_noticed_unknown_title,
        "Allow it to run it now, or dismiss it." to R.string.push_schedule_missed_body,
        "The scheduled run needs your answer to go on." to R.string.push_schedule_waiting_body,
        "Scheduled run: open it to read the result." to R.string.push_schedule_result_body,
        "pirc notifications work" to R.string.push_test_title,
        "Scheduled runs and anything waiting for you will show up here." to R.string.push_test_body,
    )

    /** A push's title from its [PushText], or null to show the one sent. */
    fun pushTitle(context: Context, text: PushText): String? {
        val a = text.args
        fun named(id: Int, name: String) = a[name]?.let { context.getString(id, it) }
        return when (text.key) {
            "potApproval" -> named(R.string.push_pot_approval_title, "pot")
            "potBudgetBlocked" -> named(R.string.push_pot_budget_blocked_title, "pot")
            "potBudgetRequest" -> named(R.string.push_pot_budget_request_title, "pot")
            "potHandover" -> named(R.string.push_pot_handover_title, "pot")
            "potReplied" -> named(R.string.push_pot_replied_title, "pot")
            "potOpenedWork" -> named(R.string.push_pot_opened_work_title, "pot")
            "potNoticed" -> named(R.string.push_pot_noticed_title, "pot")
            "scheduleFinished" -> named(R.string.push_schedule_finished_title, "schedule")
            "scheduleFailed" -> named(R.string.push_schedule_failed_title, "schedule")
            "scheduleMissed" -> named(R.string.push_schedule_missed_title, "schedule")
            "scheduleWaiting" -> named(R.string.push_schedule_waiting_title, "schedule")
            "calendarNow", "calendarStarts" -> named(R.string.push_calendar_title, "event")
            PushNote.SUMMARY_KEY -> a["count"]?.toIntOrNull()?.let {
                context.resources.getQuantityString(R.plurals.push_summary_title, it, it)
            }
            else -> null
        }
    }

    /** A push's body from its [PushText], or null to show the one sent (through [pushFixed]). */
    fun pushBody(context: Context, text: PushText): String? {
        val a = text.args
        return when (text.key) {
            "potApproval" -> {
                val provider = a["provider"] ?: return null
                val model = a["model"] ?: return null
                val work = a["work"] ?: return null
                context.getString(R.string.push_pot_approval_body, provider, model, work)
            }
            "calendarNow", "calendarStarts" -> {
                val whenText = a["when"] ?: return null
                val zone = a["timezone"] ?: return null
                val id = if (text.key == "calendarNow") R.string.push_calendar_now_body else R.string.push_calendar_starts_body
                context.getString(id, whenText, zone)
            }
            else -> null
        }
    }
}
