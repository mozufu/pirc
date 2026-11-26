package org.mozufu.pirc.notifications

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.util.Base64
import android.view.View
import android.widget.RemoteViews
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import org.mozufu.pirc.MainActivity
import org.mozufu.pirc.R

/** The Android notification channels: the four D20 categories and the summary. */
object NotificationChannels {
    const val NEEDS_YOU = "needs_you"
    const val DONE = "done"
    const val PROGRESS = "progress"
    const val CALENDAR = "calendar"

    /** The digest, and the test push (neither has a category). */
    const val SUMMARY = "summary"

    val all = listOf(NEEDS_YOU, DONE, PROGRESS, CALENDAR, SUMMARY)

    /** Creates the channels (again, harmlessly) with names in the system language. */
    fun ensure(context: Context, manager: NotificationManager) {
        for (id in all) {
            val (name, description, importance) = when (id) {
                NEEDS_YOU -> Triple(R.string.channel_needs_you, R.string.channel_needs_you_description, NotificationManager.IMPORTANCE_HIGH)
                DONE -> Triple(R.string.channel_done, R.string.channel_done_description, NotificationManager.IMPORTANCE_DEFAULT)
                PROGRESS -> Triple(R.string.channel_progress, R.string.channel_progress_description, NotificationManager.IMPORTANCE_LOW)
                CALENDAR -> Triple(R.string.channel_calendar, R.string.channel_calendar_description, NotificationManager.IMPORTANCE_HIGH)
                else -> Triple(R.string.channel_summary, R.string.channel_summary_description, NotificationManager.IMPORTANCE_DEFAULT)
            }
            manager.createNotificationChannel(
                NotificationChannel(id, context.getString(name), importance).apply {
                    this.description = context.getString(description)
                },
            )
        }
    }
}

/**
 * Signs what a notification opens, so the app follows only taps on its own notifications
 * ([MainActivity] is exported for the launcher and `pirc://pair`). The key is random per
 * install and never leaves this app's storage.
 */
class TapSigner(private val prefs: SharedPreferences) {
    private val key: ByteArray by lazy {
        // One lock for the process: two signers never create two keys.
        synchronized(KEY_LOCK) {
            prefs.getString(KEY, null)?.let { Base64.decode(it, Base64.NO_WRAP) }
                ?: ByteArray(32).also {
                    SecureRandom().nextBytes(it)
                    prefs.edit().putString(KEY, Base64.encodeToString(it, Base64.NO_WRAP)).commit()
                }
        }
    }

    fun sign(target: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return Base64.encodeToString(mac.doFinal(target.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
    }

    fun verify(target: String, signature: String?): Boolean {
        if (signature.isNullOrEmpty()) return false
        val expected = sign(target).toByteArray(Charsets.UTF_8)
        return MessageDigest.isEqual(expected, signature.toByteArray(Charsets.UTF_8))
    }

    companion object {
        private const val PREFS = "notification_taps"
        private const val KEY = "key"
        private val KEY_LOCK = Any()

        fun of(context: Context) =
            TapSigner(context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
    }
}

/** Turns [NotificationSpec]s into Android notifications and shows or removes them. */
class NotificationRenderer(
    private val context: Context,
    private val signer: TapSigner = TapSigner.of(context),
    private val manager: NotificationManager = context.getSystemService(NotificationManager::class.java),
) {
    /** The tags of this app's notifications on screen now. */
    fun shownTags(): Set<String> = runCatching {
        manager.activeNotifications.mapNotNull { it.tag }.toSet()
    }.getOrDefault(emptySet())

    /** The title of the notification with [tag] on screen now, or null. */
    fun shownTitle(tag: String): String? = runCatching {
        manager.activeNotifications.firstOrNull { it.tag == tag }
            ?.notification?.extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()
    }.getOrNull()

    /**
     * Applies [steps]. [pairingStamp] is the pairing the push came for: "Pairing ended"
     * is shown once for it, never again until the app pairs anew.
     */
    fun apply(steps: List<ReceiptStep>, pairingStamp: String? = null) {
        if (steps.isEmpty()) return
        NotificationChannels.ensure(context, manager)
        for (step in steps) {
            when (step) {
                is ReceiptStep.Show -> {
                    // "Answered on …" only updates a notification still on screen: one the
                    // quick-reply overlay removed after its own send (while this push was
                    // being read) is not posted again.
                    if (step.spec.answeredOn != null && step.spec.tag !in shownTags()) continue
                    manager.notify(step.spec.tag, ID, build(step.spec))
                }
                is ReceiptStep.Remove -> manager.cancel(step.tag, ID)
                ReceiptStep.PairingEnded -> pairingEnded(pairingStamp)
            }
        }
    }

    private fun pairingEnded(stamp: String?) {
        val prefs = context.getSharedPreferences(STATE, Context.MODE_PRIVATE)
        synchronized(STATE_LOCK) {
            if (stamp == null || prefs.getString(PAIRING_ENDED_FOR, null) == stamp) return
            prefs.edit().putString(PAIRING_ENDED_FOR, stamp).commit()
        }
        val spec = NotificationSpec(
            tag = PAIRING_ENDED_TAG,
            channel = NotificationChannels.NEEDS_YOU,
            title = context.getString(R.string.notification_pairing_ended),
            body = context.getString(R.string.notification_pairing_ended_body),
            lockScreen = "full",
            silent = false,
            open = OpenTarget.app,
        )
        manager.notify(PAIRING_ENDED_TAG, ID, build(spec))
    }

    fun build(spec: NotificationSpec): Notification {
        val body = spec.answeredOn?.let { name ->
            context.getString(R.string.notification_answered_on, name.ifEmpty { context.getString(R.string.notification_another_device) })
        } ?: spec.body
        val title = spec.title.ifBlank { context.getString(R.string.notification_app_name) }
        val builder = Notification.Builder(context, spec.channel)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(open(spec.tag, "content", spec.open))
            .setAutoCancel(true)
            .setShowWhen(true)
            .setCategory(
                when (spec.channel) {
                    NotificationChannels.NEEDS_YOU -> Notification.CATEGORY_REMINDER
                    NotificationChannels.CALENDAR -> Notification.CATEGORY_EVENT
                    else -> Notification.CATEGORY_STATUS
                },
            )
        if (spec.choices.isEmpty()) {
            builder.setStyle(Notification.BigTextStyle().bigText(body))
        } else {
            // Expanded: the question and at most 3 choices, each only opening the app.
            builder.setStyle(Notification.DecoratedCustomViewStyle())
                .setCustomBigContentView(choicesView(spec, body))
        }
        for (action in spec.actions) {
            val built = Notification.Action.Builder(null, context.getString(labelOf(action.label)), open(spec.tag, action.label.name, action.open))
            // The buttons appear only after unlock (C § 6.3).
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) built.setAuthenticationRequired(true)
            builder.addAction(built.build())
        }
        spec.timeoutMillis?.let(builder::setTimeoutAfter)
        if (spec.silent) {
            // Quiet hours: no sound or vibration. Channels own the sound, so the notification
            // joins a group of its own that alerts only for its (absent) summary, as
            // NotificationCompat's setSilent does.
            builder.setGroup("silent:${spec.tag}").setGroupAlertBehavior(Notification.GROUP_ALERT_SUMMARY)
        }
        if (spec.lockScreen == "hidden") {
            // Nothing on the lock screen, whatever Android's lock screen setting is.
            builder.setVisibility(Notification.VISIBILITY_SECRET)
        } else {
            // Private, with a public version for the lock screen. Android shows the public
            // version only while its lock screen hides sensitive content; Settings →
            // Notifications says so beside the choice.
            builder.setVisibility(Notification.VISIBILITY_PRIVATE).setPublicVersion(publicVersion(spec, title, body))
        }
        return builder.build()
    }

    /** What the lock screen shows: no buttons, and only as much text as `lockScreen` allows. */
    private fun publicVersion(spec: NotificationSpec, title: String, body: String): Notification {
        val text = if (spec.lockScreen == "full") body else context.getString(R.string.notification_unlock_to_view)
        return Notification.Builder(context, spec.channel)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .build()
    }

    private fun choicesView(spec: NotificationSpec, body: String): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.notification_question)
        views.setTextViewText(R.id.notification_question, body)
        val slots = listOf(R.id.notification_choice_1, R.id.notification_choice_2, R.id.notification_choice_3)
        slots.forEachIndexed { index, slot ->
            val choice = spec.choices.getOrNull(index)
            if (choice == null) {
                views.setViewVisibility(slot, View.GONE)
            } else {
                views.setViewVisibility(slot, View.VISIBLE)
                views.setTextViewText(slot, choice.label)
                views.setOnClickPendingIntent(slot, open(spec.tag, "choice$index", choice.open))
            }
        }
        return views
    }

    /** An explicit, immutable intent straight to [MainActivity] (no service in between). */
    private fun open(tag: String, role: String, target: OpenTarget): PendingIntent {
        val intent = openIntent(context, signer, target)
            // Makes each tag, button and choice its own PendingIntent.
            .setIdentifier("$tag|$role|${target.key}")
        return PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    companion object {
        const val ID = 0
        const val PAIRING_ENDED_TAG = "pairing-ended"
        private const val STATE = "notifications"
        private const val PAIRING_ENDED_FOR = "pairingEndedFor"
        private val STATE_LOCK = Any()
        const val ACTION_OPEN = "org.mozufu.pirc.OPEN_NOTIFICATION"
        const val EXTRA_TARGET = "org.mozufu.pirc.notificationTarget"
        const val EXTRA_SIGNATURE = "org.mozufu.pirc.notificationSignature"

        /**
         * The signed intent that opens [target] in [MainActivity], as a notification tap
         * does; the quick-reply overlay starts it directly.
         */
        fun openIntent(context: Context, signer: TapSigner, target: OpenTarget): Intent {
            val json = target.json()
            return Intent(context, MainActivity::class.java)
                .setAction(ACTION_OPEN)
                .putExtra(EXTRA_TARGET, json)
                .putExtra(EXTRA_SIGNATURE, signer.sign(json))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }

        fun labelOf(label: ActionLabel) = when (label) {
            ActionLabel.ANSWER -> R.string.notification_answer
            ActionLabel.OPEN_CONVERSATION -> R.string.notification_open_conversation
            ActionLabel.VIEW_AND_RUN -> R.string.notification_view_and_run
            ActionLabel.SKIP -> R.string.notification_skip
        }
    }
}
