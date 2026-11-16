package dev.pirc.pirc_mobile

import dev.pirc.android.core.Pairing
import dev.pirc.android.core.defaultHttpClient
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.CookieJar
import java.io.ByteArrayOutputStream

/**
 * Image GETs use browser cookie scope. The pairing bearer credential goes only to the gateway
 * origin and only for requests the app initiated; once a redirect leaves that origin it is not
 * restored. Page content (the default) never carries it.
 */
class NativeImageTransport internal constructor(
    private val pairing: Pairing?,
    client: OkHttpClient = sharedClient,
    private val limit: Int = 32 * 1024 * 1024,
    private val cookies: NativeDocumentCookies? = null,
    private val initiator: RequestInitiator = RequestInitiator.Content,
) {
    companion object { private val sharedClient = defaultHttpClient() }
    private val httpClient = client.newBuilder()
        .cookieJar(CookieJar.NO_COOKIES)
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
        .build()
    private val base = pairing?.baseUrl?.plus("/")?.toHttpUrlOrNull()
    private fun sameOrigin(a: HttpUrl, b: HttpUrl) = a.scheme == b.scheme && a.host == b.host && a.port == b.port
    fun load(
        source: String,
        baseUrl: String? = null,
        initiatorUrl: String? = null,
        topLevelUrl: String? = null,
    ): Map<String, Any> {
        val blobBase = baseUrl?.startsWith("blob:", ignoreCase = true) == true
        val resolutionBase = when {
            blobBase -> {
                NativeScriptResourceTransport.originForBlobUrl(checkNotNull(baseUrl))
                null
            }
            baseUrl != null -> baseUrl.toHttpUrlOrNull() ?: error("Image base URL is unavailable")
            else -> base
        }
        var url = if (blobBase) {
            source.toHttpUrlOrNull() ?: error("Image URL must be absolute when the document base is a blob URL")
        } else {
            resolutionBase?.resolve(source) ?: source.toHttpUrlOrNull() ?: error("Image URL is unavailable")
        }
        val cookieInitiator = nativeCookieContextUrl(initiatorUrl)
        val cookieTopLevel = nativeCookieContextUrl(topLevelUrl, cookieInitiator)
        var crossedCookieSiteBoundary = false
        var requestCookieKey = opaqueCookieRequestKey(null)
        var setCookieProcessed = false
        var authorizationMayBeSent = true
        repeat(11) { hop ->
            require(url.username.isEmpty() && url.password.isEmpty()) { "Image URL contains credentials" }
            val request = Request.Builder().url(url).header("Accept", "image/*")
            val cookieContext = CookieRequestContext(
                initiatorUrl = cookieInitiator,
                topLevelUrl = cookieTopLevel,
                method = "GET",
                topLevelNavigation = false,
                credentialsEnabled = true,
                crossSiteRedirect = crossedCookieSiteBoundary,
            )
            val cookiesApply = cookiesMayApply(initiator, pairing, base, url)
            val cookieHeader = if (cookiesApply) cookies?.requestHeader(url, cookieContext) else null
            requestCookieKey = opaqueCookieRequestKey(cookieHeader)
            cookieHeader?.let { request.header("Cookie", it) }
            if (authorizationMayBeSent && initiator.mayCarry(pairing) && base != null && sameOrigin(url, base)) request.header("Authorization", "Bearer "+pairing!!.token)
            httpClient.newCall(request.build()).execute().use { response ->
                setCookieProcessed = (cookiesApply && receiveNativeSetCookies(
                    cookies,
                    url,
                    response,
                    cookieContext,
                )) || setCookieProcessed
                if (response.code in listOf(301, 302, 303, 307, 308)) {
                    check(hop < 10) { "Too many image redirects" }
                    val target = url.resolve(response.header("Location") ?: error("Image redirect has no location")) ?: error("Invalid image redirect")
                    if (!NativeDocumentCookies.schemefulSameSite(url, target)) {
                        crossedCookieSiteBoundary = true
                    }
                    if (!sameOrigin(url, target)) authorizationMayBeSent = false
                    url = target
                } else {
                    check(response.isSuccessful) { NativeI18n.text("Image request failed ({0})", response.code) }
                    val body = response.body
                    check(body.contentLength() <= limit) { "Image exceeds 32 MiB" }
                    val out = ByteArrayOutputStream()
                    body.byteStream().use { input ->
                        val buffer = ByteArray(8192)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            check(out.size() + count <= limit) { "Image exceeds 32 MiB" }
                            out.write(buffer, 0, count)
                        }
                    }
                    return mapOf(
                        "bytes" to out.toByteArray(),
                        "mimeType" to response.header("Content-Type").orEmpty()
                            .substringBefore(';').trim().lowercase(),
                        "nativeCookieRequestKey" to requestCookieKey,
                        "nativeSetCookieProcessed" to setCookieProcessed,
                    )
                }
            }
        }
        error("Too many image redirects")
    }
}
