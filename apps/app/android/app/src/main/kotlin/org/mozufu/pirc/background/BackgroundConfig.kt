package org.mozufu.pirc.background

import android.content.Context
import android.content.SharedPreferences
import java.util.UUID
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** Where the background client connects, as the app last saved it. Holds no secret. */
data class BackgroundTarget(
    val gateway: HttpUrl,
    val clientId: String,
    /** A random value per pairing: work begun under one pairing never finishes under another. */
    val pairingStamp: String,
)

/**
 * The Gateway URL and the app's client ID for work done without the Flutter engine (push
 * receipt, the quick-reply overlay). Flutter keeps both in its own preferences, which
 * Kotlin does not read; the app gives them through the `push` channel when it is online
 * with a pairing and clears them when it unpairs. The device token stays in the Keystore
 * ([org.mozufu.pirc.credentials.KeystoreCredentialStore]) and is never stored here.
 */
class BackgroundConfig(private val prefs: SharedPreferences) {
    /** The saved target, or null when the app is not paired (or never told Kotlin). */
    fun read(): BackgroundTarget? {
        val gateway = prefs.getString(GATEWAY, null)?.toHttpUrlOrNull() ?: return null
        val clientId = prefs.getString(CLIENT_ID, null)?.takeIf { it.isNotEmpty() } ?: return null
        val stamp = prefs.getString(STAMP, null)?.takeIf { it.isNotEmpty() } ?: return null
        return BackgroundTarget(gateway, clientId, stamp)
    }

    /**
     * Saves [gateway] and [clientId]. The pairing stamp stays while the Gateway is the
     * same; a new Gateway, or the first save after [clear], starts a new one.
     */
    fun save(gateway: String, clientId: String): BackgroundTarget {
        val url = gateway.toHttpUrlOrNull()
        require(url != null && (url.scheme == "https" || url.scheme == "http")) { "gateway must be an http(s) URL" }
        require(clientId.isNotEmpty() && clientId.length <= 200) { "clientId must not be empty" }
        synchronized(this) {
            val same = prefs.getString(GATEWAY, null) == url.toString()
            val stamp = prefs.getString(STAMP, null)?.takeIf { same && it.isNotEmpty() } ?: UUID.randomUUID().toString()
            prefs.edit()
                .putString(GATEWAY, url.toString())
                .putString(CLIENT_ID, clientId)
                .putString(STAMP, stamp)
                .commit()
            return BackgroundTarget(url, clientId, stamp)
        }
    }

    /** The app unpaired: nothing is read or sent in the background any more. */
    fun clear() {
        synchronized(this) { prefs.edit().clear().commit() }
    }

    companion object {
        private const val PREFS = "background"
        private const val GATEWAY = "gateway"
        private const val CLIENT_ID = "clientId"
        private const val STAMP = "pairingStamp"

        fun of(context: Context) = BackgroundConfig(
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE),
        )
    }
}
