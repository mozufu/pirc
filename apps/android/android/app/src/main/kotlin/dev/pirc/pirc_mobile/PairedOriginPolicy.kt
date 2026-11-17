package dev.pirc.pirc_mobile

import dev.pirc.android.core.Pairing
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * Which documents may run script.
 *
 * Bytes served by the paired origin are the app's own data. They are shown as inert content
 * (text, images, files, downloads, the app's recognition of its own Web shell) but are never
 * given a script execution environment, are never used as same-origin script, stylesheet or fetch
 * resources for content, and never receive the paired origin's cookie or storage scope.
 *
 * The decision is made from the final response URL that the native transport computed, or from
 * the document URL a script session is opened for, and always against the pairing held by the
 * native runtime. Nothing a page, a bridge argument or a flag supplied by Dart can name selects an
 * exemption.
 */
internal object PairedOriginPolicy {
    const val ERROR_CODE = "SCRIPT_PAIRED_ORIGIN"

    /** True when [url] has exactly the origin (scheme, host, port) of the paired Gateway. */
    fun isPairedOrigin(pairingOrigin: HttpUrl?, url: HttpUrl): Boolean =
        pairingOrigin != null && sameNativeOrigin(url, pairingOrigin)

    /** The paired origin as an [HttpUrl], or null when unpaired or the saved base is not an HTTP URL. */
    fun originOf(pairing: Pairing?): HttpUrl? = pairing?.baseUrl?.toHttpUrlOrNull()

    /**
     * True when the serialized document origin returned by
     * [NativeScriptResourceTransport.originForDocument] is the paired origin. `"null"` (an opaque
     * origin) is never the paired origin.
     */
    fun isPairedOrigin(pairing: Pairing?, documentOrigin: String): Boolean {
        val paired = originOf(pairing) ?: return false
        val parsed = documentOrigin.toHttpUrlOrNull() ?: return false
        return sameNativeOrigin(parsed, paired)
    }

    /**
     * Refuses a script session for a document on the paired origin, whether it is a plain
     * document or a blob document created by one. The origin is recomputed here from the URL, so
     * a document reached by redirect, history or a blob is judged by where it really lives.
     */
    fun requireScriptable(pairing: Pairing?, documentUrl: String, blobCreatorUrl: String? = null) {
        val origin = NativeScriptResourceTransport.originForDocument(documentUrl, blobCreatorUrl)
        if (isPairedOrigin(pairing, origin)) {
            throw DocumentScriptException(
                ERROR_CODE,
                NativeI18n.text("Documents served by the paired Gateway are shown as inert content and do not run script."),
            )
        }
    }
}
