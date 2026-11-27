package org.mozufu.pirc.overlay

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject
import org.mozufu.pirc.background.BackgroundClient
import org.mozufu.pirc.background.BackgroundResult
import org.mozufu.pirc.notifications.OpenTarget

/** What the overlay is about: an agent question or a missed run (default E). */
sealed interface OverlayItem {
    /** The tag of the item's notification, which the overlay leaves in place. */
    val tag: String

    /** Names the item in the store of uncertain sends. */
    val key: String

    /** What the top right button and "Open conversation" open: the step 3 tap target. */
    val open: OpenTarget

    data class Question(
        val sessionId: String,
        val interactionId: String,
        val epoch: String,
        override val tag: String,
    ) : OverlayItem {
        override val key get() = "question:$sessionId:$interactionId:$epoch"
        override val open get() = OpenTarget.question(sessionId, interactionId, epoch)
    }

    data class Run(val scheduleId: String, val runId: String, override val tag: String) : OverlayItem {
        override val key get() = "run:$scheduleId:$runId"
        override val open get() = OpenTarget.run(scheduleId, runId)
    }
}

/** One option; [other] marks the agent's "Other" option, shown with the app's own words. */
data class OverlayChoice(val id: String, val label: String, val other: Boolean = false)

/** Who holds the session's control lease, from the compact read. */
sealed interface OverlayControl {
    /** This device holds it, or nobody does: a send needs no takeover. */
    data object Mine : OverlayControl

    /**
     * Another device holds it: a send takes it first. [name] is null when the Gateway
     * knows no name, [clientId] when an older Gateway did not say; [recent] when that device acted within 30 seconds, so the send asks
     * once more first, as the composer does.
     */
    data class Other(val name: String?, val recent: Boolean, val clientId: String? = null) : OverlayControl
}

enum class RunAction { RUN, SKIP }

/** The states of C § 6.4 and plans/roadmap.md M8 step 4. Buttons are enabled only in a ready state. */
sealed interface OverlayState {
    /** "Checking the latest state…", every button disabled. */
    data class Checking(val run: Boolean) : OverlayState

    /** A question that still takes an answer. Choices come only from the compact read. */
    data class Question(
        val sessionName: String?,
        val title: String,
        val message: String?,
        val choices: List<OverlayChoice>,
        val selected: String?,
        val expiresAt: Long?,
        val control: OverlayControl,
        /** The holder acted lately: the next press of Send takes control and sends. */
        val confirmTakeover: Boolean = false,
        val sending: Boolean = false,
    ) : OverlayState {
        val canSend get() = !sending && selected != null && choices.any { it.id == selected }
    }

    /** A run that is still missed. */
    data class Run(
        val title: String?,
        val dueAt: Long?,
        val reason: String?,
        /** The decision being sent; buttons are disabled meanwhile. */
        val sending: RunAction? = null,
    ) : OverlayState

    /** Sent; the overlay closes by itself. [action] is null for an answer. */
    data class Sent(val action: RunAction?) : OverlayState

    /** Answered on another device (or before): the result and "OK". */
    data class AnsweredElsewhere(
        val deviceName: String?,
        val at: Long?,
        val title: String? = null,
        val sessionName: String? = null,
    ) : OverlayState

    /** No longer answerable: expired, cancelled, or a newer run of the agent. */
    data class Expired(val title: String? = null, val sessionName: String? = null) : OverlayState

    /** The state could not be read, or a send could not start. "Retry" reads again. */
    data class Offline(val run: Boolean) : OverlayState

    /** Taking control failed: who holds it, and "Open conversation". */
    data class NoControl(val holder: String?) : OverlayState

    /** The outcome of a send is unknown. Its command ID is never sent again. */
    data class NotSure(val run: Boolean) : OverlayState

    /** Not shown: the overlay closes (the pairing ended, or the device is not paired). */
    data object Closing : OverlayState

    /** The run is no longer missed: its current state (`running`, `completed`, …, or null when gone). */
    data class RunSettled(val state: String?) : OverlayState
}

/** The background client's calls that the overlay uses. */
interface OverlayGateway {
    fun interaction(sessionId: String, interactionId: String): BackgroundResult

    fun scheduleRun(scheduleId: String, runId: String): BackgroundResult

    fun takeControl(sessionId: String): BackgroundResult

    fun answer(sessionId: String, interactionId: String, answer: JSONObject, commandId: String): BackgroundResult

    fun allowRun(scheduleId: String, runId: String, commandId: String): BackgroundResult

    fun dismissRun(scheduleId: String, runId: String, commandId: String): BackgroundResult

    companion object {
        fun of(client: BackgroundClient) = object : OverlayGateway {
            override fun interaction(sessionId: String, interactionId: String) = client.interaction(sessionId, interactionId)

            override fun scheduleRun(scheduleId: String, runId: String) = client.scheduleRun(scheduleId, runId)

            override fun takeControl(sessionId: String) = client.takeControl(sessionId)

            override fun answer(sessionId: String, interactionId: String, answer: JSONObject, commandId: String) =
                client.answer(sessionId, interactionId, answer, commandId)

            override fun allowRun(scheduleId: String, runId: String, commandId: String) =
                client.allowRun(scheduleId, runId, commandId)

            override fun dismissRun(scheduleId: String, runId: String, commandId: String) =
                client.dismissRun(scheduleId, runId, commandId)
        }
    }
}

/**
 * The overlay's sends whose outcome is unknown, by item. A command ID is written here
 * (with `commit`) before its request goes out and removed once the outcome is known, so
 * a send that never came back blocks every later send of that item from the overlay,
 * across services and process deaths (N8). The app finds out by reading the state.
 *
 * Each value is `<written at>|<command ID>`. Marks older than [MAX_AGE] are dropped by
 * [prune]: by then the question has expired and a run decision is checked against the
 * run's state before it is sent.
 */
class UncertainSends(private val prefs: SharedPreferences, private val now: () -> Long = System::currentTimeMillis) {
    fun commandOf(key: String): String? = prefs.getString(key, null)?.let { it.substringAfter('|') }

    /** False when it could not be written; then nothing may be sent. */
    fun mark(key: String, commandId: String): Boolean = prefs.edit().putString(key, "${now()}|$commandId").commit()

    fun clear(key: String) {
        prefs.edit().remove(key).commit()
    }

    /** Drops marks older than [MAX_AGE]. */
    fun prune() {
        val oldest = now() - MAX_AGE
        val stale = prefs.all.filter { (_, value) ->
            val at = (value as? String)?.substringBefore('|', "")?.toLongOrNull()
            at == null || at < oldest
        }.keys
        if (stale.isNotEmpty()) prefs.edit().apply { stale.forEach(::remove) }.commit()
    }

    companion object {
        private const val PREFS = "overlay_uncertain"
        const val MAX_AGE = 24 * 60 * 60_000L

        fun of(context: Context) = UncertainSends(context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
    }
}
