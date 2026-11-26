package org.mozufu.pirc.links

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.URI
import java.net.URISyntaxException
import org.mozufu.pirc.PlatformFeature

/**
 * The `pirc://pair?…` link an intent carries, or null for any other data. The manifest
 * registers only this link (plans/roadmap.md M8 "More defaults"); Dart checks the rest of
 * it, as it does for a pasted link.
 */
internal fun pairLinkOf(data: String?): String? {
    if (data.isNullOrBlank() || data.length > MAX_LINK_LENGTH) return null
    val uri = try {
        URI(data)
    } catch (_: URISyntaxException) {
        return null
    }
    return data.takeIf { uri.scheme.equals("pirc", ignoreCase = true) && uri.host == "pair" }
}

/**
 * The pairing link of the intent that started the activity, or null. A launch from
 * Recents (`FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`) or a restore ([restored]) carries
 * the intent of the first launch again, whose link was already given.
 */
internal fun launchLinkOf(intent: Intent?, restored: Boolean): String? {
    if (intent == null || restored) return null
    if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
    return pairLinkOf(intent.dataString)
}

/** An address the browser may open: http or https with a host. */
internal fun browserAddressOf(url: String?): String? {
    if (url.isNullOrBlank() || url.length > MAX_LINK_LENGTH) return null
    val uri = try {
        URI(url)
    } catch (_: URISyntaxException) {
        return null
    }
    val scheme = uri.scheme?.lowercase()
    return url.takeIf { (scheme == "https" || scheme == "http") && !uri.host.isNullOrEmpty() }
}

private const val MAX_LINK_LENGTH = 4096

/**
 * `org.mozufu.pirc/links`: pairing links into the app and addresses out to the browser.
 * - `initialLink` → the `pirc://pair` link that opened the app, or one that arrived
 *   while Dart was not listening; it is given once, and [consumed] then clears it from
 *   the activity's intent.
 * - `openBrowser {url}`: opens an http(s) address in the browser (the pairing v2
 *   approval page). Errors: `INVALID`, `NO_BROWSER`.
 * - To Dart, `link` with the link as its argument when one arrives while the app runs.
 *
 * A pairing link holds a token, so it is never logged.
 */
class LinksChannel internal constructor(
    initialIntentData: String?,
    private val openUrl: (String) -> Unit,
    private val consumed: () -> Unit = {},
) : PlatformFeature {
    override val name = "links"

    private var channel: MethodChannel? = null

    /** The link Dart has not taken yet. */
    private var pending: String? = pairLinkOf(initialIntentData)

    override fun attached(channel: MethodChannel) {
        this.channel = channel
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialLink" -> {
                val link = pending
                pending = null
                if (link != null) consumed()
                result.success(link)
            }
            "openBrowser" -> {
                val url = browserAddressOf(call.argument<String>("url"))
                if (url == null) {
                    result.error("INVALID", "url must be an http or https address", null)
                    return
                }
                try {
                    openUrl(url)
                    result.success(null)
                } catch (_: ActivityNotFoundException) {
                    result.error("NO_BROWSER", "No app can open this address", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    override fun newIntent(intent: Intent) {
        val link = launchLinkOf(intent, restored = false) ?: return
        pending = link
        val channel = channel ?: return
        // Kept as pending until Dart takes it, so a link that arrives before Dart
        // listens is read with `initialLink`.
        channel.invokeMethod(
            "link",
            link,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (pending == link) {
                        pending = null
                        consumed()
                    }
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}

                override fun notImplemented() {}
            },
        )
    }

    override fun detach() {
        channel = null
    }

    companion object {
        /** [restored]: the activity was created again from saved state. */
        fun create(activity: Activity, restored: Boolean) = LinksChannel(
            initialIntentData = launchLinkOf(activity.intent, restored),
            consumed = { activity.intent?.data = null },
            openUrl = { url ->
                activity.startActivity(
                    Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE),
                )
            },
        )
    }
}
