package dev.pirc.pirc_mobile

import dev.pirc.android.core.Pairing
import okhttp3.HttpUrl
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Who caused a native network request.
 *
 * The paired credential is attached only when the destination is the paired origin and the
 * request was started by the app itself. That is a property of the Kotlin code path that builds
 * the request: [Content] is the default of every transport, so a call site that says nothing
 * carries no credential. [App] can only be minted by [AppRequestAuthority], which is held by the
 * native runtime; nothing that arrives over the bridge (URLs, origins, referrers, flags) selects it.
 */
internal sealed interface RequestInitiator {
    /** True when this initiator may attach [pairing]'s credential to the next hop. */
    fun mayCarry(pairing: Pairing?): Boolean

    /** Page content, script, form, link or unspecified: never carries the paired credential. */
    object Content : RequestInitiator {
        override fun mayCarry(pairing: Pairing?): Boolean = false
    }

    /** A request the app itself started, bound to one pairing and revoked with its authority. */
    class App internal constructor(
        private val bound: Pairing,
        private val live: AtomicBoolean,
    ) : RequestInitiator {
        override fun mayCarry(pairing: Pairing?): Boolean =
            pairing != null && pairing == bound && live.get()
    }
}

/**
 * Process-local issuer of [RequestInitiator.App] handles. Every outstanding handle is revoked when
 * the account scope changes (unpair, pairing to another server, pairing-stamp rotation), so a
 * request that is still redirecting afterwards, or a handle kept from an earlier account, no
 * longer authorizes any credential.
 */
internal class AppRequestAuthority {
    private val lock = Any()
    private var live = AtomicBoolean(true)

    fun issue(pairing: Pairing): RequestInitiator.App =
        synchronized(lock) { RequestInitiator.App(pairing, live) }

    fun revokeAll() {
        synchronized(lock) {
            live.set(false)
            live = AtomicBoolean(true)
        }
    }
}

internal fun sameNativeOrigin(first: HttpUrl, second: HttpUrl): Boolean =
    first.scheme == second.scheme && first.host == second.host && first.port == second.port

/**
 * Cookies belong to the page that set them. A request that is not app-initiated neither sends
 * cookies to nor stores cookies from the paired origin, so that origin's cookie scope cannot be
 * used to carry identity on behalf of content.
 */
internal fun cookiesMayApply(
    initiator: RequestInitiator,
    pairing: Pairing?,
    pairingOrigin: HttpUrl?,
    url: HttpUrl,
): Boolean =
    pairingOrigin == null || !sameNativeOrigin(url, pairingOrigin) || initiator.mayCarry(pairing)
