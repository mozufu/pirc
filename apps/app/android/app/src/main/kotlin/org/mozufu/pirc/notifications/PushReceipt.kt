package org.mozufu.pirc.notifications

import org.json.JSONObject
import org.mozufu.pirc.background.BackgroundResult
import org.mozufu.pirc.background.long
import org.mozufu.pirc.background.text

/**
 * What a tap opens, as the app reads it from the `notifications` channel. It names IDs
 * and, for a question, the choice the user tapped; never a secret and never an answer
 * the app has not checked.
 */
data class OpenTarget(val fields: Map<String, String>) {
    fun json(): String = JSONObject(fields).toString()

    /** Distinguishes PendingIntents that differ only in their target. */
    val key: String get() = fields.entries.sortedBy { it.key }.joinToString("|") { "${it.key}=${it.value}" }

    companion object {
        /** The app checks the question first, then preselects [choice] when it is still open. */
        fun question(sessionId: String, interactionId: String, epoch: String, choice: String? = null, label: String? = null) =
            OpenTarget(
                buildMap {
                    put("type", "question")
                    put("sessionId", sessionId)
                    put("interactionId", interactionId)
                    put("epoch", epoch)
                    if (choice != null) put("choice", choice)
                    if (label != null) put("label", label)
                },
            )

        fun session(sessionId: String) = OpenTarget(mapOf("type" to "session", "sessionId" to sessionId))

        /** [action] `view` ("View and run") or `skip` ("Skip…"); both only open the app. */
        fun run(scheduleId: String, runId: String, action: String = "view") =
            OpenTarget(mapOf("type" to "run", "scheduleId" to scheduleId, "runId" to runId, "action" to action))

        val schedules = OpenTarget(mapOf("type" to "schedules"))

        fun calendar(eventId: String?, occurrenceStart: String?) = OpenTarget(
            buildMap {
                put("type", "calendar")
                if (eventId != null) put("eventId", eventId)
                if (occurrenceStart != null) put("occurrenceStart", occurrenceStart)
            },
        )

        fun approval(id: String) = OpenTarget(mapOf("type" to "approval", "approvalId" to id))

        fun budget(id: String) = OpenTarget(mapOf("type" to "budget", "budgetRequestId" to id))

        fun thread(potId: String, threadId: String) =
            OpenTarget(mapOf("type" to "thread", "potId" to potId, "threadId" to threadId))

        fun activityNotification(id: String) =
            OpenTarget(mapOf("type" to "activityNotification", "activityNotificationId" to id))

        val activity = OpenTarget(mapOf("type" to "activity"))

        val notificationSettings = OpenTarget(mapOf("type" to "settings"))

        val app = OpenTarget(mapOf("type" to "app"))
    }
}

/** The labels of notification buttons; the renderer looks up their strings. */
enum class ActionLabel { ANSWER, OPEN_CONVERSATION, VIEW_AND_RUN, SKIP }

data class NotificationAction(val label: ActionLabel, val open: OpenTarget)

/** A choice of the expanded question; it only opens the app with the choice preselected. */
data class NotificationChoice(val label: String, val open: OpenTarget)

/** One notification to show, before Android strings and PendingIntents are added. */
data class NotificationSpec(
    val tag: String,
    /** The Android channel: a D20 category, or `summary`. */
    val channel: String,
    /** Empty means the app's name. */
    val title: String,
    val body: String,
    val lockScreen: String,
    val silent: Boolean,
    val open: OpenTarget,
    val actions: List<NotificationAction> = emptyList(),
    /** At most 3, and only from a compact read that said the question is open. */
    val choices: List<NotificationChoice> = emptyList(),
    /** "Answered on <device>": the body is built from this name. */
    val answeredOn: String? = null,
    /** Removed by Android after this long. */
    val timeoutMillis: Long? = null,
)

sealed interface ReceiptStep {
    data class Show(val spec: NotificationSpec) : ReceiptStep

    data class Remove(val tag: String) : ReceiptStep

    /** The Gateway refused the token (401): say once that the pairing ended. */
    data object PairingEnded : ReceiptStep
}

/** The two compact reads of the background client (plans/roadmap.md M8 step 0.5). */
interface CompactReads {
    fun interaction(sessionId: String, interactionId: String): BackgroundResult

    fun scheduleRun(scheduleId: String, runId: String): BackgroundResult
}

/**
 * Decides what a push does to the notifications (C § 6.3). Questions and missed runs are
 * read through [reads] first: choices and run buttons appear only when the read says the
 * item is still open, and a read that fails shows the push's own text without them. The
 * other kinds show the push's text, which never holds an answer.
 *
 * [shown] lists the tags of the notifications on screen now and [shownTitle] the title of
 * one of them; [now] is the clock.
 */
class PushReceipt(
    private val reads: CompactReads,
    private val shown: () -> Set<String>,
    private val now: () -> Long = System::currentTimeMillis,
    private val shownTitle: (String) -> String? = { null },
) {
    fun plan(note: PushNote): List<ReceiptStep> = when (val kind = note.kind) {
        is PushKind.Question -> question(note, kind)
        is PushKind.Answered -> answered(note, kind)
        is PushKind.Refresh -> refresh(kind)
        is PushKind.Run -> run(note, kind)
        is PushKind.Session -> show(note, OpenTarget.session(kind.sessionId))
        PushKind.Schedules -> show(note, OpenTarget.schedules)
        is PushKind.Calendar -> show(note, OpenTarget.calendar(kind.eventId, kind.occurrenceStart))
        is PushKind.Approval -> show(note, OpenTarget.approval(kind.approvalId))
        is PushKind.BudgetRequest -> show(note, OpenTarget.budget(kind.budgetRequestId))
        is PushKind.PotThread -> show(note, OpenTarget.thread(kind.potId, kind.threadId))
        is PushKind.ActivityNotification -> show(note, OpenTarget.activityNotification(kind.id))
        PushKind.Summary -> show(note, OpenTarget.activity)
        PushKind.Test -> show(note, OpenTarget.notificationSettings)
        PushKind.Other -> show(note, OpenTarget.app)
    }

    /** A read that did not say the state: [plain] without buttons, or nothing. */
    private fun unread(read: BackgroundResult, tag: String, plain: NotificationSpec): List<ReceiptStep> = when (read) {
        is BackgroundResult.Refused -> when (read.status) {
            404 -> listOf(ReceiptStep.Remove(tag))
            401 -> listOf(ReceiptStep.PairingEnded)
            // 403 and other refusals, and 5xx: the push's own text, nothing to choose.
            else -> listOf(ReceiptStep.Show(plain))
        }
        is BackgroundResult.Unreachable, is BackgroundResult.NotSure -> listOf(ReceiptStep.Show(plain))
        BackgroundResult.Unpaired, is BackgroundResult.Done -> emptyList()
    }

    /** Removed by Android when the question stops taking answers. */
    private fun untilExpiry(expiresAt: Long?): Long? = expiresAt?.let { it - now() }?.takeIf { it > 0 }

    private fun question(note: PushNote, q: PushKind.Question): List<ReceiptStep> {
        val open = OpenTarget.question(q.sessionId, q.interactionId, q.epoch)
        val actions = listOf(
            NotificationAction(ActionLabel.ANSWER, open),
            NotificationAction(ActionLabel.OPEN_CONVERSATION, OpenTarget.session(q.sessionId)),
        )
        // Already past its expiry when it is handled: never posted.
        val expiredByPush = note.expiresAt?.let { it <= now() } == true
        val plain = spec(note, open).copy(actions = actions, timeoutMillis = untilExpiry(note.expiresAt))
        val read = reads.interaction(q.sessionId, q.interactionId)
        if (read !is BackgroundResult.Done) {
            return if (expiredByPush) listOf(ReceiptStep.Remove(note.tag)) else unread(read, note.tag, plain)
        }
        val body = read.body ?: return listOf(if (expiredByPush) ReceiptStep.Remove(note.tag) else ReceiptStep.Show(plain))
        // The compact read's expiry, else the push's.
        val expires = body.long("expiresAt") ?: note.expiresAt
        val pending = body.text("state") == "pending" &&
            body.text("epoch") == q.epoch &&
            (expires == null || expires > now())
        if (!pending) return listOf(ReceiptStep.Remove(note.tag))
        val question = body.optJSONObject("question")?.text("title")?.takeIf { it.isNotBlank() }
        val choices = body.optJSONArray("choices")
        val listed = buildList {
            if (choices != null) {
                for (i in 0 until minOf(choices.length(), MAX_CHOICES)) {
                    val choice = choices.optJSONObject(i) ?: continue
                    val id = choice.text("id") ?: continue
                    val label = choice.text("label") ?: id
                    add(NotificationChoice(label, OpenTarget.question(q.sessionId, q.interactionId, q.epoch, id, label)))
                }
            }
        }
        // More than 3 options is never sent as choices; a longer list is not cut.
        val usable = if ((choices?.length() ?: 0) > MAX_CHOICES) emptyList() else listed
        return listOf(
            ReceiptStep.Show(
                plain.copy(
                    body = question ?: note.body,
                    choices = usable,
                    timeoutMillis = untilExpiry(expires),
                ),
            ),
        )
    }

    private fun answered(note: PushNote, a: PushKind.Answered): List<ReceiptStep> {
        if (note.tag !in shown()) return emptyList()
        val read = reads.interaction(a.sessionId, a.interactionId)
        // The question can no longer be confirmed open: take its buttons away.
        if (read !is BackgroundResult.Done) return listOf(ReceiptStep.Remove(note.tag))
        val body = read.body
        return when (body?.text("state")) {
            "answered" -> listOf(
                ReceiptStep.Show(
                    NotificationSpec(
                        tag = note.tag,
                        channel = channelOf(note),
                        // The notification's own title (the session's), never the question:
                        // the lock screen may show the title.
                        title = shownTitle(note.tag)?.takeIf { it.isNotBlank() } ?: note.title,
                        body = "",
                        lockScreen = note.lockScreen,
                        // An update never sounds again.
                        silent = true,
                        open = OpenTarget.session(a.sessionId),
                        answeredOn = body.optJSONObject("answeredBy")?.text("deviceName")?.takeIf { it.isNotBlank() } ?: "",
                        timeoutMillis = ANSWERED_TIMEOUT,
                    ),
                ),
            )
            "pending" -> emptyList()
            else -> listOf(ReceiptStep.Remove(note.tag))
        }
    }

    private fun refresh(r: PushKind.Refresh): List<ReceiptStep> = shown().mapNotNull { tag ->
        val (session, epoch, interaction) = PushNote.parseQuestionTag(tag) ?: return@mapNotNull null
        if (session != r.sessionId) return@mapNotNull null
        when (val read = reads.interaction(session, interaction)) {
            is BackgroundResult.Done -> {
                val body = read.body
                val pending = body?.text("state") == "pending" && body.text("epoch") == epoch
                if (pending) null else ReceiptStep.Remove(tag)
            }
            is BackgroundResult.Refused -> if (read.status == 404) ReceiptStep.Remove(tag) else null
            else -> null
        }
    }

    private fun run(note: PushNote, r: PushKind.Run): List<ReceiptStep> {
        val view = OpenTarget.run(r.scheduleId, r.runId)
        val plain = spec(note, view)
        val read = reads.scheduleRun(r.scheduleId, r.runId)
        if (read !is BackgroundResult.Done) return unread(read, note.tag, plain)
        return when (read.body?.optJSONObject("run")?.text("state")) {
            "missed" -> listOf(
                ReceiptStep.Show(
                    plain.copy(
                        actions = listOf(
                            NotificationAction(ActionLabel.VIEW_AND_RUN, view),
                            NotificationAction(ActionLabel.SKIP, OpenTarget.run(r.scheduleId, r.runId, "skip")),
                        ),
                    ),
                ),
            )
            // Failed, or waiting, without a session: the push's own text.
            "failed", "waiting_input", null -> listOf(ReceiptStep.Show(plain))
            // A finished run is news only as a "done" push; a missed one that ran since is not.
            "completed" -> if (note.category == "done") {
                listOf(ReceiptStep.Show(plain))
            } else {
                listOf(ReceiptStep.Remove(note.tag))
            }
            // Allowed (running), dismissed or skipped meanwhile: nothing waits any more.
            else -> listOf(ReceiptStep.Remove(note.tag))
        }
    }

    private fun show(note: PushNote, open: OpenTarget) = listOf(ReceiptStep.Show(spec(note, open)))

    private fun spec(note: PushNote, open: OpenTarget) = NotificationSpec(
        tag = note.tag,
        channel = channelOf(note),
        title = note.title,
        body = note.body,
        lockScreen = note.lockScreen,
        silent = note.silent,
        open = open,
    )

    companion object {
        const val MAX_CHOICES = 3
        const val ANSWERED_TIMEOUT = 5_000L

        /** The Android channel of a push: its category, or `summary` for the digest and the test. */
        fun channelOf(note: PushNote): String = note.category ?: NotificationChannels.SUMMARY
    }
}
