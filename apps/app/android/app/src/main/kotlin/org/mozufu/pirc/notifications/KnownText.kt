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
}
