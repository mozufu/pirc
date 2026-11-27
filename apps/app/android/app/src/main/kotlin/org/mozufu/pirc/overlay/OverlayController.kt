package org.mozufu.pirc.overlay

import java.util.UUID
import java.util.concurrent.Executor
import org.json.JSONObject
import org.mozufu.pirc.background.BackgroundResult
import org.mozufu.pirc.background.long
import org.mozufu.pirc.background.text
import org.mozufu.pirc.notifications.OpenTarget

/** What the controller asks of the window. All calls come on the main thread. */
interface OverlayEffects {
    fun render(state: OverlayState)

    /** Closes the overlay; the item and its notification stay. */
    fun close()

    /** This device answered or decided: the item's notification goes. */
    fun removeNotification(tag: String)

    /** Opens the app on [target] (signed as a notification tap) and closes the overlay. */
    fun open(target: OpenTarget)
}

/**
 * The quick-reply overlay's state machine (C § 6.4). It starts in "Checking the latest
 * state…" and reads the compact state through [gateway]; choices appear only from that
 * read. A send takes the control lease when another device holds it, then sends the
 * answer with a fresh command ID; a missed run is read again before "Run now" or "Skip",
 * and the decision goes out only while it is still missed.
 *
 * Network calls run on [io]; results come back through [main] and are dropped once a
 * newer read started or the controller was disposed. The bookkeeping of [uncertain] is
 * done on [io] whatever the window does meanwhile.
 */
class OverlayController(
    val item: OverlayItem,
    private val clientId: String,
    private val gateway: OverlayGateway,
    private val uncertain: UncertainSends,
    private val effects: OverlayEffects,
    private val io: Executor,
    private val main: Executor,
    /** Runs a task on the main thread after a delay; the result cancels it. */
    private val later: (Long, Runnable) -> () -> Unit,
    private val now: () -> Long = System::currentTimeMillis,
    private val newCommandId: () -> String = { UUID.randomUUID().toString() },
    private val sentCloseMillis: Long = SENT_CLOSE_MILLIS,
) {
    var state: OverlayState = OverlayState.Checking(item is OverlayItem.Run)
        private set

    private var generation = 0L
    private var disposed = false
    private var timer: (() -> Unit)? = null

    /** The run was shown as missed at least once. */
    private var runSeenReady = false

    /** The choice the user picked; a later read keeps it while it is still offered. */
    private var selection: String? = null

    /** When "Take control and send" appeared. */
    private var confirmShownAt = 0L

    /** Reads the state again (the first read, "Retry", or a push about the item). */
    fun check() {
        if (disposed || sending) return
        val run = item is OverlayItem.Run
        val token = begin()
        set(OverlayState.Checking(run))
        val seenReady = runSeenReady
        io.execute {
            val next = when (item) {
                is OverlayItem.Question -> questionOf(gateway.interaction(item.sessionId, item.interactionId), item)
                is OverlayItem.Run -> runOf(gateway.scheduleRun(item.scheduleId, item.runId), item).let {
                    // Only a missed run opens the overlay (default E). A push about a run
                    // that failed or finished, read before the user saw it missed, gets
                    // its notification alone.
                    if (it is OverlayState.RunSettled && !seenReady) CLOSE else it
                }
            }
            deliver(token, next)
        }
    }

    /**
     * A push about the item (answered elsewhere, the session changed). It reads again
     * without leaving a ready question, so a selected choice stays; in an end state
     * (sent, answered, expired, no longer missed) and while a send is out it does nothing.
     */
    fun recheck() {
        if (disposed || sending) return
        when (state) {
            is OverlayState.Sent, is OverlayState.AnsweredElsewhere, is OverlayState.Expired,
            is OverlayState.RunSettled, OverlayState.Closing,
            -> return
            is OverlayState.Question -> {
                val item = item as? OverlayItem.Question ?: return
                val token = begin()
                io.execute { deliver(token, questionOf(gateway.interaction(item.sessionId, item.interactionId), item)) }
            }
            else -> check()
        }
    }

    fun select(choiceId: String) {
        val current = state as? OverlayState.Question ?: return
        if (current.sending || current.choices.none { it.id == choiceId }) return
        selection = choiceId
        set(current.copy(selected = choiceId, confirmTakeover = false))
    }

    /**
     * "Send answer". The question is read again first, so the decision uses who holds
     * control now, not when the overlay opened. When another device holds it and acted in
     * the last 30 seconds, the send stops at "Take control and send" until the user
     * presses again (presses in the first [CONFIRM_GUARD_MILLIS] are ignored, so a double
     * tap does not pass it). Then control is taken and the answer goes out with a new
     * command ID.
     */
    fun send() {
        val current = state as? OverlayState.Question ?: return
        val item = item as? OverlayItem.Question ?: return
        if (!current.canSend || disposed) return
        if (current.confirmTakeover && now() - confirmShownAt < CONFIRM_GUARD_MILLIS) return
        val choice = current.selected ?: return
        // The device the user agreed to take control from, if they did.
        val agreed = if (current.confirmTakeover) current.control as? OverlayControl.Other else null
        val token = begin()
        set(current.copy(sending = true))
        io.execute {
            val fresh = questionOf(gateway.interaction(item.sessionId, item.interactionId), item)
            if (fresh !is OverlayState.Question || fresh.choices.none { it.id == choice }) {
                // No longer pending, unreadable, or its choices changed: show what is there now.
                return@execute deliver(token, fresh)
            }
            val control = fresh.control
            // The user agreed for this holder: the same client (and name). Without an
            // agreement there is none, even when the holder has no name.
            val other = control as? OverlayControl.Other
            val agreedHere = agreed != null && other != null && agreed.clientId == other.clientId && agreed.name == other.name
            if (other != null && other.recent && !agreedHere) {
                return@execute deliver(token, fresh.copy(selected = choice, confirmTakeover = true))
            }
            if (control is OverlayControl.Other) {
                when (val taken = gateway.takeControl(item.sessionId)) {
                    is BackgroundResult.Done -> Unit
                    is BackgroundResult.Refused -> return@execute deliver(
                        token,
                        when (taken.status) {
                            401 -> CLOSE
                            // A real refusal (a conflict, another user's lease): who holds it.
                            in 400..499 -> OverlayState.NoControl(control.name)
                            // A 5xx: the Gateway or the node could not answer. Nothing was sent.
                            else -> OverlayState.Offline(run = false)
                        },
                    )
                    BackgroundResult.Unpaired -> return@execute deliver(token, CLOSE)
                    // Unreachable: nothing was answered, so trying again is safe.
                    else -> return@execute deliver(token, OverlayState.Offline(run = false))
                }
            }
            val result = sendOnce { commandId ->
                gateway.answer(item.sessionId, item.interactionId, JSONObject().put("value", choice), commandId)
            }
            val next = when (result) {
                is BackgroundResult.Done -> OverlayState.Sent(null)
                is BackgroundResult.Refused -> if (result.status == 401) {
                    CLOSE
                } else {
                    // No longer answerable, most often: say what the state is now.
                    when (val read = questionOf(gateway.interaction(item.sessionId, item.interactionId), item)) {
                        is OverlayState.Question -> OverlayState.Offline(run = false)
                        else -> read
                    }
                }
                else -> outcomeOf(result, run = false)
            }
            deliver(token, next)
        }
    }

    /** "Run now" or "Skip" of a missed run. */
    fun decide(action: RunAction) {
        val current = state as? OverlayState.Run ?: return
        val item = item as? OverlayItem.Run ?: return
        if (current.sending != null || disposed) return
        val token = begin()
        set(current.copy(sending = action))
        io.execute {
            // Read the run again: the decision goes out only while it is still missed.
            when (val fresh = runOf(gateway.scheduleRun(item.scheduleId, item.runId), item)) {
                is OverlayState.Run -> Unit
                else -> return@execute deliver(token, fresh)
            }
            val result = sendOnce { commandId ->
                when (action) {
                    RunAction.RUN -> gateway.allowRun(item.scheduleId, item.runId, commandId)
                    RunAction.SKIP -> gateway.dismissRun(item.scheduleId, item.runId, commandId)
                }
            }
            val next = when (result) {
                is BackgroundResult.Done -> OverlayState.Sent(action)
                is BackgroundResult.Refused -> if (result.status == 401) {
                    CLOSE
                } else {
                    when (val read = runOf(gateway.scheduleRun(item.scheduleId, item.runId), item)) {
                        is OverlayState.Run -> OverlayState.Offline(run = true)
                        else -> read
                    }
                }
                else -> outcomeOf(result, run = true)
            }
            deliver(token, next)
        }
    }

    /** The overlay closes: late results are dropped, timers stop. Nothing is answered. */
    fun dispose() {
        disposed = true
        generation++
        timer?.invoke()
        timer = null
    }

    /** A send or a decision is out. */
    val sending: Boolean
        get() = when (val s = state) {
            is OverlayState.Question -> s.sending
            is OverlayState.Run -> s.sending != null
            else -> false
        }

    /**
     * Sends one decision with a new command ID, written to [uncertain] first. The mark
     * stays only when the outcome is unknown. Runs on [io].
     */
    private fun sendOnce(send: (String) -> BackgroundResult): BackgroundResult {
        val commandId = newCommandId()
        // Check and mark at once for the whole process: two overlays of one item can
        // never both send.
        synchronized(SEND_LOCK) {
            // A send of this item whose outcome is unknown: never send again.
            uncertain.commandOf(item.key)?.let { return BackgroundResult.NotSure(it, null) }
            if (!uncertain.mark(item.key, commandId)) {
                return BackgroundResult.Unreachable(IllegalStateException("Could not save the command ID"))
            }
        }
        val result = try {
            send(commandId)
        } catch (error: RuntimeException) {
            // Whether it went out is unknown; the mark stays.
            BackgroundResult.NotSure(commandId, error)
        }
        if (result !is BackgroundResult.NotSure) uncertain.clear(item.key)
        return result
    }

    private fun outcomeOf(result: BackgroundResult, run: Boolean): OverlayState = when (result) {
        is BackgroundResult.NotSure -> OverlayState.NotSure(run)
        BackgroundResult.Unpaired -> CLOSE
        else -> OverlayState.Offline(run)
    }

    private fun questionOf(read: BackgroundResult, item: OverlayItem.Question): OverlayState {
        if (read !is BackgroundResult.Done) return unread(read, run = false)
        val body = read.body ?: return OverlayState.Offline(run = false)
        val expiresAt = body.long("expiresAt")
        val state = body.text("state")
        val question = body.optJSONObject("question")
        val title = question?.text("title")?.takeIf { it.isNotBlank() }
        val sessionName = body.text("sessionName")
        if (body.text("epoch") != item.epoch) return settled(OverlayState.Expired(title, sessionName))
        if (state == "answered") {
            val by = body.optJSONObject("answeredBy")
            return settled(OverlayState.AnsweredElsewhere(by?.text("deviceName"), by?.long("at"), title, sessionName))
        }
        if (state != "pending" || (expiresAt != null && expiresAt <= now())) {
            return settled(OverlayState.Expired(title, sessionName))
        }
        if (uncertain.commandOf(item.key) != null) return OverlayState.NotSure(run = false)
        val list = body.optJSONArray("choices")
        // The agent's "Other" option (`other`) is not counted toward the limit.
        val counted = list?.let { all -> (0 until all.length()).count { all.optJSONObject(it)?.optBoolean("other") != true } } ?: 0
        val choices = buildList {
            if (list != null && counted <= MAX_CHOICES) {
                for (i in 0 until list.length()) {
                    val choice = list.optJSONObject(i) ?: continue
                    val id = choice.text("id") ?: continue
                    add(OverlayChoice(id, choice.text("label") ?: id, choice.optBoolean("other")))
                }
            }
        }
        val holder = body.optJSONObject("controlHolder")
        val holderId = holder?.text("clientId")
        val control = if (holder == null || holderId == null || holderId == clientId) {
            // No live lease, or this device's: a send needs no takeover. A holder
            // without a clientId comes from an older Gateway; it is treated as another.
            if (holder != null && holderId == null) other(holder) else OverlayControl.Mine
        } else {
            other(holder)
        }
        return OverlayState.Question(
            sessionName = sessionName,
            title = title ?: "",
            message = question?.text("message")?.takeIf { it.isNotBlank() },
            choices = choices,
            selected = null,
            expiresAt = expiresAt,
            control = control,
        )
    }

    private fun other(holder: JSONObject): OverlayControl.Other {
        val last = holder.long("lastActionAt")
        return OverlayControl.Other(holder.text("name"), last != null && now() - last < RECENT_MILLIS, holder.text("clientId"))
    }

    private fun runOf(read: BackgroundResult, item: OverlayItem.Run): OverlayState {
        if (read !is BackgroundResult.Done) {
            if (read is BackgroundResult.Refused && read.status == 404) return settled(OverlayState.RunSettled(null))
            return unread(read, run = true)
        }
        val run = read.body?.optJSONObject("run") ?: return OverlayState.Offline(run = true)
        val state = run.text("state")
        if (state != "missed") return settled(OverlayState.RunSettled(state))
        if (uncertain.commandOf(item.key) != null) return OverlayState.NotSure(run = true)
        return OverlayState.Run(run.text("title"), run.long("dueAt"), run.text("reason"))
    }

    /** The item no longer waits: an uncertain send of it has nothing left to block. */
    private fun settled(state: OverlayState): OverlayState {
        uncertain.clear(item.key)
        return state
    }

    private fun unread(read: BackgroundResult, run: Boolean): OverlayState = when {
        read is BackgroundResult.Refused && read.status == 404 -> settled(OverlayState.Expired())
        read is BackgroundResult.Refused && read.status == 401 -> CLOSE
        read == BackgroundResult.Unpaired -> CLOSE
        else -> OverlayState.Offline(run)
    }

    private fun begin(): Long {
        timer?.invoke()
        timer = null
        return ++generation
    }

    private fun deliver(token: Long, next: OverlayState) {
        main.execute {
            if (disposed || token != generation) return@execute
            if (next === CLOSE) {
                effects.close()
                return@execute
            }
            val shownNext = if (next is OverlayState.Question && next.selected == null && next.choices.any { it.id == selection }) {
                next.copy(selected = selection)
            } else {
                next
            }
            set(shownNext)
            if (shownNext is OverlayState.Question && shownNext.confirmTakeover) confirmShownAt = now()
            if (next is OverlayState.Run) runSeenReady = true
            when (next) {
                is OverlayState.Sent -> {
                    effects.removeNotification(item.tag)
                    timer = later(sentCloseMillis) { if (!disposed) effects.close() }
                }
                is OverlayState.Question -> next.expiresAt?.let { at ->
                    timer = later((at - now()).coerceAtLeast(0)) {
                        val current = state
                        if (!disposed && current is OverlayState.Question && !current.sending) {
                            generation++
                            set(OverlayState.Expired(current.title, current.sessionName))
                        }
                    }
                }
                else -> Unit
            }
        }
    }

    private fun set(next: OverlayState) {
        state = next
        effects.render(next)
    }

    /** Opens the item in the app (the top right, and the buttons that say so). */
    fun openConversation() {
        if (!disposed) effects.open(item.open)
    }

    companion object {
        const val MAX_CHOICES = 3
        const val SENT_CLOSE_MILLIS = 1_500L
        const val RECENT_MILLIS = 30_000L
        const val CONFIRM_GUARD_MILLIS = 500L

        private val CLOSE = OverlayState.Closing
        private val SEND_LOCK = Any()
    }
}
