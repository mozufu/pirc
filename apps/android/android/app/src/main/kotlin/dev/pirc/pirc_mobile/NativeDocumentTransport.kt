package dev.pirc.pirc_mobile

import dev.pirc.android.core.Pairing
import dev.pirc.android.core.defaultHttpClient
import java.io.ByteArrayOutputStream
import java.nio.charset.Charset
import java.security.MessageDigest
import java.util.Locale
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** Opaque cache identity for the exact Cookie header sent on one native request hop. */
internal fun opaqueCookieRequestKey(cookieHeader: String?): String {
    val bytes = MessageDigest.getInstance("SHA-256")
        .digest(cookieHeader.orEmpty().toByteArray(Charsets.UTF_8))
    val hex = "0123456789abcdef"
    return buildString(bytes.size * 2) {
        bytes.forEach { byte ->
            val value = byte.toInt() and 0xff
            append(hex[value ushr 4])
            append(hex[value and 0x0f])
        }
    }
}

/** Parses a document-site URL without borrowing its Referrer, Origin or HTML base metadata. */
internal fun nativeCookieContextUrl(value: String?, fallback: HttpUrl? = null): HttpUrl? {
    if (value == null) return fallback
    if (value == "null") return null
    if (value.startsWith("blob:", ignoreCase = true)) {
        return NativeScriptResourceTransport.originForBlobUrl(value).toHttpUrlOrNull()
    }
    val parsed = value.toHttpUrlOrNull()
        ?: throw IllegalArgumentException("Cookie initiator must be an HTTP(S) URL or null")
    require(parsed.scheme == "http" || parsed.scheme == "https") {
        "Cookie initiator must be an HTTP(S) URL or null"
    }
    require(parsed.username.isEmpty() && parsed.password.isEmpty()) {
        "Cookie initiator must not contain credentials"
    }
    return parsed
}

/** Process unfiltered Set-Cookie fields before redirect, CORS, cache or body handling. */
internal fun receiveNativeSetCookies(
    cookies: NativeDocumentCookies?,
    url: HttpUrl,
    response: okhttp3.Response,
    context: CookieRequestContext,
): Boolean {
    val headers = response.headers.values("Set-Cookie")
    if (cookies == null || headers.isEmpty()) return false
    cookies.receive(url, headers, context)
    return true
}

/**
 * Performs native GET/POST document navigations and follows their HTTP redirects.
 *
 * This carries form bytes as UTF-8, applies navigation redirect method rules, and computes Referer
 * for top-level document requests. It manually applies the optional browser cookie store on each
 * hop, while the underlying OkHttp CookieJar is disabled. The pairing bearer token is added only
 * for the exact pairing origin and only for requests the app itself initiated; a redirect that
 * leaves the pairing origin ends that for the rest of the chain.
 */
class NativeDocumentTransport internal constructor(
    private val pairing: Pairing?,
    client: OkHttpClient = sharedClient,
    private val limit: Int = DEFAULT_LIMIT,
    private val cookies: NativeDocumentCookies? = null,
    /** Who started these requests; anything not declared as the app never carries the credential. */
    private val initiator: RequestInitiator = RequestInitiator.Content,
) {
    enum class ResourceType { DOCUMENT, STYLESHEET, MEDIA }
    enum class CacheMode { DEFAULT, RELOAD, REVALIDATE }

    companion object {
        private const val DEFAULT_LIMIT = 32 * 1024 * 1024
        private const val MAX_REDIRECTS = 10
        private const val MAX_VALIDATOR_BYTES = 8 * 1024
        private const val MAX_REFERRER_URL_LENGTH = 4096
        private const val DEFAULT_REFERRER_POLICY = "strict-origin-when-cross-origin"
        private const val DEFAULT_FORM_CONTENT_TYPE = "application/x-www-form-urlencoded;charset=UTF-8"
        private const val ACCEPT_DOCUMENT =
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        private const val ACCEPT_STYLESHEET = "text/css,*/*;q=0.1"
        private const val ACCEPT_MEDIA = "audio/*,video/*,*/*;q=0.1"
        private val FORM_CHARSET_PARAMETER = Regex("^charset=\"?utf-8\"?$", RegexOption.IGNORE_CASE)
        private val FORM_BOUNDARY_PARAMETER =
            Regex("^boundary=(?:\"[0-9A-Za-z'()+_,./:=?-]{1,70}\"|[0-9A-Za-z'()+_,./:=?-]{1,70})$")

        private val REFERRER_POLICIES = setOf(
            "no-referrer",
            "no-referrer-when-downgrade",
            "origin",
            "origin-when-cross-origin",
            "same-origin",
            "strict-origin",
            "strict-origin-when-cross-origin",
            "unsafe-url",
        )
        private val sharedClient = defaultHttpClient()
        private val RELEVANT_RESPONSE_HEADERS = listOf(
            "Content-Type",
            "Content-Disposition",
            "Refresh",
            "Referrer-Policy",
            "Location",
            "ETag",
            "Last-Modified",
            "Date",
            "Age",
            "Expires",
            "Cache-Control",
            "Vary",
        )
        private val COMBINABLE_RESPONSE_HEADERS = setOf("Cache-Control", "Vary", "Referrer-Policy")
        private val SINGLETON_CACHE_HEADERS =
            setOf("ETag", "Last-Modified", "Date", "Age", "Expires")
    }

    private val httpClient = client.newBuilder()
        .cookieJar(CookieJar.NO_COOKIES)
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
        .build()

    private val pairingOrigin = pairing?.let { parseAbsoluteUrl(it.baseUrl, "Pairing URL") }

    init {
        require(limit >= 0) { "Document response limit must not be negative" }
    }

    /**
     * Resolves [source] without making a request. A relative source uses [baseUrl], or the pairing
     * origin when [baseUrl] is omitted. Uses OkHttp HttpUrl parsing and serialization, not the full
     * WHATWG URL algorithm; callers should not assume every browser URL alias canonicalizes alike.
     */
    fun resolveUrl(source: String, baseUrl: String? = null): String =
        resolveHttpUrl(source, baseUrl).toString()

    /**
     * Loads an HTTP(S) resource. [baseUrl] is used to resolve relative URLs; when omitted,
     * relative URLs resolve against the pairing origin. [resourceType] selects only the Accept
     * value and method constraint; pairing authorization remains scoped to the pairing origin.
     * [cacheMode] is a cache hint; forced reload is GET-only, while revalidation can also apply
     * to POST. Typed validators are GET-only and are sent only
     * for the initial representation URL (ignoring its fragment), never after redirecting away.
     * [referrerUrl], [referrerPolicy], and [originUrl] carry the initiating document context and
     * affect only [ResourceType.DOCUMENT] requests. Origin is sent only on POST hops.
     */
    fun load(
        url: String,
        method: String,
        body: String?,
        contentType: String?,
        baseUrl: String? = null,
        resourceType: ResourceType = ResourceType.DOCUMENT,
        cacheMode: CacheMode = CacheMode.DEFAULT,
        ifNoneMatch: String? = null,
        ifModifiedSince: String? = null,
        bodyBytes: ByteArray? = null,
        referrerUrl: String? = null,
        referrerPolicy: String? = null,
        originUrl: String? = null,
        initiatorUrl: String? = null,
        topLevelUrl: String? = null,
    ): Map<String, Any?> {
        var requestMethod = method.uppercase(Locale.ROOT)
        require(requestMethod == "GET" || requestMethod == "POST") {
            "Document navigation only supports GET and POST"
        }
        require(resourceType == ResourceType.DOCUMENT || requestMethod == "GET") {
            "Stylesheet and media requests only support GET"
        }
        require(body == null || bodyBytes == null) {
            "Document body must be text or bytes, not both"
        }
        require(requestMethod == "POST" || (body == null && bodyBytes == null)) {
            "GET document navigation cannot have a request body"
        }
        require(
            requestMethod == "GET" ||
                cacheMode == CacheMode.DEFAULT ||
                cacheMode == CacheMode.REVALIDATE
        ) {
            "Forced document reload only supports GET"
        }
        val conditionalEntityTag = validateConditionalHeader("If-None-Match", ifNoneMatch)
        val conditionalLastModified =
            validateConditionalHeader("If-Modified-Since", ifModifiedSince)
        require(requestMethod == "GET" ||
            (conditionalEntityTag == null && conditionalLastModified == null)
        ) {
            "Conditional document headers only support GET"
        }

        var requestBody = if (requestMethod == "POST") {
            bodyBytes?.copyOf() ?: (body ?: "").toByteArray(Charsets.UTF_8)
        } else {
            null
        }
        var requestContentType = if (requestMethod == "POST") validatedFormContentType(contentType) else null
        var authorizationMayBeSent = true

        var currentUrl = resolveHttpUrl(url, baseUrl)
        val initialRepresentationUrl = withoutFragment(currentUrl)
        val cookieInitiator = nativeCookieContextUrl(
            initiatorUrl,
            currentUrl.takeIf { resourceType == ResourceType.DOCUMENT },
        )
        val cookieTopLevel = nativeCookieContextUrl(topLevelUrl, cookieInitiator)
        var crossedCookieSiteBoundary = false
        var requestCookieKey = opaqueCookieRequestKey(null)
        var setCookieProcessed = false
        var validatorsStillBoundToInitialUrl = true
        var referrerSource = if (resourceType == ResourceType.DOCUMENT) referrerUrl else null
        var activeReferrerPolicy = if (resourceType == ResourceType.DOCUMENT) {
            initialReferrerPolicy(referrerPolicy)
        } else {
            "no-referrer"
        }
        val originalSourceOrigin = if (resourceType == ResourceType.DOCUMENT) {
            sourceOrigin(originUrl, referrerUrl)
        } else {
            null
        }
        var effectiveSourceOrigin = originalSourceOrigin

        for (hop in 0..MAX_REDIRECTS) {
            val accept = when (resourceType) {
                ResourceType.DOCUMENT -> ACCEPT_DOCUMENT
                ResourceType.STYLESHEET -> ACCEPT_STYLESHEET
                ResourceType.MEDIA -> ACCEPT_MEDIA
            }
            val request = Request.Builder()
                .url(currentUrl)
                .header("Accept", accept)

            val cookieContext = CookieRequestContext(
                initiatorUrl = cookieInitiator,
                topLevelUrl = cookieTopLevel,
                method = requestMethod,
                topLevelNavigation = resourceType == ResourceType.DOCUMENT,
                credentialsEnabled = true,
                crossSiteRedirect = crossedCookieSiteBoundary,
            )
            val cookiesApply = cookiesMayApply(initiator, pairing, pairingOrigin, currentUrl)
            val cookieHeader = if (cookiesApply) cookies?.requestHeader(currentUrl, cookieContext) else null
            requestCookieKey = opaqueCookieRequestKey(cookieHeader)
            cookieHeader?.let { request.header("Cookie", it) }

            when (cacheMode) {
                CacheMode.DEFAULT -> Unit
                CacheMode.RELOAD -> request
                    .header("Cache-Control", "no-cache")
                    .header("Pragma", "no-cache")
                CacheMode.REVALIDATE -> request.header("Cache-Control", "max-age=0")
            }

            val representationUrl = withoutFragment(currentUrl)
            if (requestMethod == "GET" &&
                cacheMode != CacheMode.RELOAD &&
                validatorsStillBoundToInitialUrl &&
                representationUrl == initialRepresentationUrl
            ) {
                conditionalEntityTag?.let { request.header("If-None-Match", it) }
                conditionalLastModified?.let { request.header("If-Modified-Since", it) }
            }

            val requestReferrer = if (resourceType == ResourceType.DOCUMENT) {
                referrerForTarget(
                    cappedReferrerSource(referrerSource, currentUrl),
                    activeReferrerPolicy,
                    currentUrl,
                )
            } else {
                ""
            }
            val requestReferrerPolicy = activeReferrerPolicy
            if (requestReferrer.isNotEmpty()) {
                request.header("Referer", requestReferrer)
            }

            if (resourceType == ResourceType.DOCUMENT && requestMethod == "POST") {
                request.header(
                    "Origin",
                    originForRequest(
                        cappedSourceOrigin(effectiveSourceOrigin),
                        activeReferrerPolicy,
                        currentUrl,
                    ),
                )
            }

            if (requestMethod == "POST") {
                val type = checkNotNull(requestContentType)
                request.header("Content-Type", type)
                request.post(
                    checkNotNull(requestBody).toRequestBody(type.toMediaTypeOrNull()),
                )
            } else {
                request.get()
            }

            if (authorizationMayBeSent &&
                initiator.mayCarry(pairing) &&
                pairingOrigin?.let { sameOrigin(currentUrl, it) } == true
            ) {
                request.header("Authorization", "Bearer ${checkNotNull(pairing).token}")
            }

            var redirected = false
            httpClient.newCall(request.build()).execute().use { response ->
                setCookieProcessed = (cookiesApply && receiveNativeSetCookies(
                    cookies,
                    currentUrl,
                    response,
                    cookieContext,
                )) || setCookieProcessed
                val location = response.header("Location")
                if (response.code in REDIRECT_CODES && location != null) {
                    check(hop < MAX_REDIRECTS) { "Too many document redirects" }
                    val resolvedTarget = currentUrl.resolve(location)
                        ?: throw IllegalArgumentException("Invalid document redirect URL")
                    val target = if (
                        resolvedTarget.encodedFragment == null && currentUrl.encodedFragment != null
                    ) {
                        resolvedTarget.newBuilder()
                            .encodedFragment(currentUrl.encodedFragment)
                            .build()
                    } else {
                        resolvedTarget
                    }
                    val validatedTarget = validateUrl(target, "Document redirect URL")
                    if (!NativeDocumentCookies.schemefulSameSite(currentUrl, validatedTarget)) {
                        crossedCookieSiteBoundary = true
                    }
                    if (!sameOrigin(currentUrl, validatedTarget)) {
                        // One way: a chain that has left this origin never gets the credential back.
                        authorizationMayBeSent = false
                    }
                    if (resourceType == ResourceType.DOCUMENT) {
                        // Redirect policies can only reprocess the value this request disclosed.
                        // An empty or reduced Referer never regains the initiating document URL.
                        referrerSource = response.request.header("Referer").orEmpty()
                        activeReferrerPolicy = updateReferrerPolicy(
                            activeReferrerPolicy,
                            response.headers.values("Referrer-Policy"),
                        )
                        val currentOrigin = serializedOrigin(currentUrl)
                        val targetOrigin = serializedOrigin(validatedTarget)
                        if (currentOrigin != targetOrigin &&
                            originalSourceOrigin != currentOrigin
                        ) {
                            // Fetch taints the request origin after a second cross-origin
                            // transition. Policy-based `Origin: null` alone is not taint.
                            effectiveSourceOrigin = null
                        }
                    }
                    if (withoutFragment(validatedTarget) != initialRepresentationUrl) {
                        validatorsStillBoundToInitialUrl = false
                    }
                    currentUrl = validatedTarget

                    if (response.code == 303 ||
                        (response.code in POST_TO_GET_CODES && requestMethod == "POST")
                    ) {
                        requestMethod = "GET"
                        requestBody = null
                        requestContentType = null
                    }
                    redirected = true
                } else {
                    val actualRequestReferrer = if (resourceType == ResourceType.DOCUMENT) {
                        response.request.header("Referer").orEmpty()
                    } else {
                        ""
                    }
                    val actualRequestOrigin = if (resourceType == ResourceType.DOCUMENT) {
                        response.request.header("Origin")
                    } else {
                        null
                    }
                    return responseResult(
                        response,
                        currentUrl,
                        actualRequestReferrer,
                        requestReferrerPolicy,
                        actualRequestOrigin,
                        originalSourceOrigin ?: "null",
                        requestCookieKey,
                        setCookieProcessed,
                    )
                }
            }

            if (redirected) continue
        }

        error("Too many document redirects")
    }

    private fun responseResult(
        response: okhttp3.Response,
        finalUrl: HttpUrl,
        requestReferrer: String,
        requestReferrerPolicy: String,
        requestOrigin: String?,
        requestOriginSource: String,
        requestCookieKey: String,
        setCookieProcessed: Boolean,
    ): Map<String, Any?> {
        val contentType = response.header("Content-Type")
        val bytes = if (response.code == 204 || response.code == 205 || response.code == 304) {
            byteArrayOf()
        } else {
            readBounded(response.body)
        }
        val relevantHeaders = buildMap {
            RELEVANT_RESPONSE_HEADERS.forEach { name ->
                val values = response.headers.values(name)
                val value = when {
                    name in COMBINABLE_RESPONSE_HEADERS ->
                        values.takeIf { it.isNotEmpty() }?.joinToString(", ")
                    name in SINGLETON_CACHE_HEADERS -> values.singleOrNull()
                    else -> response.header(name)
                }
                value?.let { put(name, it) }
            }
        }

        return mapOf(
            "bytes" to bytes,
            "finalUrl" to finalUrl.toString(),
            "mimeType" to mimeType(contentType),
            "charset" to charsetName(contentType),
            "status" to response.code,
            "finalMethod" to response.request.method,
            "requestReferrer" to requestReferrer,
            "requestReferrerPolicy" to requestReferrerPolicy,
            "requestOrigin" to requestOrigin,
            "requestOriginSource" to requestOriginSource,
            "requestSentAt" to response.sentRequestAtMillis,
            "receivedAt" to response.receivedResponseAtMillis,
            "headersRelevant" to relevantHeaders,
            "nativeCookieRequestKey" to requestCookieKey,
            "nativeSetCookieProcessed" to setCookieProcessed,
        )
    }

    private fun readBounded(body: okhttp3.ResponseBody?): ByteArray {
        if (body == null) return byteArrayOf()

        val declaredLength = body.contentLength()
        check(declaredLength < 0 || declaredLength <= limit) {
            "Document response exceeds the configured size limit"
        }

        val output = ByteArrayOutputStream()
        body.byteStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                check(output.size().toLong() + count <= limit.toLong()) {
                    "Document response exceeds the configured size limit"
                }
                output.write(buffer, 0, count)
            }
        }
        return output.toByteArray()
    }

    private fun validateConditionalHeader(name: String, value: String?): String? {
        if (value == null) return null
        require('\r' !in value && '\n' !in value) {
            "$name must not contain CR or LF"
        }
        require(value.toByteArray(Charsets.UTF_8).size <= MAX_VALIDATOR_BYTES) {
            "$name exceeds the configured size limit"
        }
        return value
    }

    private fun withoutFragment(url: HttpUrl): HttpUrl =
        url.newBuilder().fragment(null).build()

    private fun parseAbsoluteUrl(value: String, label: String): HttpUrl {
        val parsed = value.toHttpUrlOrNull()
            ?: throw IllegalArgumentException("$label must be an HTTP(S) URL")
        return validateUrl(parsed, label)
    }

    private fun resolveHttpUrl(source: String, baseUrl: String?): HttpUrl {
        if (baseUrl?.startsWith("blob:", ignoreCase = true) == true) {
            // Blob documents inherit an origin but their URL is not an HTTP base URL.
            // Keep absolute HTTP(S) resources usable while rejecting relative ones instead
            // of resolving them against the pairing origin or creator page.
            NativeScriptResourceTransport.originForBlobUrl(baseUrl)
            val absolute = source.toHttpUrlOrNull()
                ?: throw IllegalArgumentException(
                    "Document URL must be absolute when the base URL is a blob URL",
                )
            return validateUrl(absolute, "Document URL")
        }
        val resolutionBase = baseUrl?.let { parseAbsoluteUrl(it, "Base URL") } ?: pairingOrigin
        val resolved = if (resolutionBase != null) {
            resolutionBase.resolve(source) ?: source.toHttpUrlOrNull()
                ?: throw IllegalArgumentException("Document URL must be an HTTP(S) URL")
        } else {
            source.toHttpUrlOrNull()
                ?: throw IllegalArgumentException("Document URL must be an absolute HTTP(S) URL")
        }
        return validateUrl(resolved, "Document URL")
    }

    private fun validateUrl(url: HttpUrl, label: String): HttpUrl {
        require(url.scheme == "http" || url.scheme == "https") {
            "$label must use HTTP or HTTPS"
        }
        require(url.username.isEmpty() && url.password.isEmpty()) {
            "$label must not contain credentials"
        }
        return url
    }

    /**
     * Only the three standard form encodings may be sent. Content chooses the encoding through
     * markup, so anything else (for example a JSON or arbitrary media type) is refused here
     * regardless of what the caller assembled. Returns the value to send.
     */
    private fun validatedFormContentType(value: String?): String {
        if (value == null) return DEFAULT_FORM_CONTENT_TYPE
        require(value.length <= 256 && value.none { it.code < 0x20 || it.code == 0x7f }) {
            "Unsupported document form encoding"
        }
        val parts = value.split(';')
        val essence = parts.first().trim().lowercase(Locale.ROOT)
        val parameters = parts.drop(1).map { it.trim() }.filter { it.isNotEmpty() }
        when (essence) {
            "application/x-www-form-urlencoded", "text/plain" -> require(
                parameters.all { FORM_CHARSET_PARAMETER.matches(it) },
            ) { "Unsupported document form encoding" }
            "multipart/form-data" -> require(
                parameters.size == 1 && FORM_BOUNDARY_PARAMETER.matches(parameters.single()),
            ) { "Unsupported document form encoding" }
            else -> throw IllegalArgumentException("Unsupported document form encoding")
        }
        return value
    }

    /**
     * A document on the paired origin is the app's own surface. Unless the app itself started the
     * request, that document's URL never leaves the paired origin in Referer, whatever policy the
     * content asks for: content may only tighten the policy, never loosen it.
     */
    private fun cappedReferrerSource(source: String?, target: HttpUrl): String? {
        if (source.isNullOrEmpty() || pairingOrigin == null || initiator.mayCarry(pairing)) return source
        val parsed = source.toHttpUrlOrNull() ?: return source
        return if (sameOrigin(parsed, pairingOrigin) && !sameOrigin(target, pairingOrigin)) "" else source
    }

    /**
     * Content on the paired origin is not first-party: unless the app started the request, its
     * Origin is opaque ("null") for every destination, the paired origin included.
     */
    private fun cappedSourceOrigin(source: String?): String? {
        if (source == null || pairingOrigin == null || initiator.mayCarry(pairing)) return source
        val parsed = source.toHttpUrlOrNull() ?: return source
        return if (sameOrigin(parsed, pairingOrigin)) null else source
    }

    private fun initialReferrerPolicy(value: String?): String {
        var policy = DEFAULT_REFERRER_POLICY
        value.orEmpty().split(',').forEach { token ->
            val candidate = token.trim().lowercase(Locale.ROOT)
            if (candidate in REFERRER_POLICIES) policy = candidate
        }
        return policy
    }

    private fun updateReferrerPolicy(current: String, values: List<String>): String {
        var policy = current
        values.forEach { value ->
            value.split(',').forEach { token ->
                val candidate = token.trim().lowercase(Locale.ROOT)
                if (candidate in REFERRER_POLICIES) policy = candidate
            }
        }
        return policy
    }

    /**
     * Canonicalizes the initiating origin separately from Referer. Callers should pass an
     * HTTP(S) source origin or the opaque-origin serialization `null`; older callers may omit it
     * and let us derive an HTTP(S) origin from their source URL.
     */
    private fun sourceOrigin(originUrl: String?, referrerUrl: String?): String? {
        val value = originUrl ?: referrerUrl ?: return null
        if (value == "null") return null
        val parsed = value.toHttpUrlOrNull()
            ?.takeIf { it.scheme == "http" || it.scheme == "https" }
            ?: return null
        return serializedOrigin(parsed)
    }

    /** The Fetch request-origin header is either an origin serialization or `null`. */
    private fun originForRequest(
        sourceOrigin: String?,
        policy: String,
        target: HttpUrl,
    ): String {
        if (sourceOrigin == null || policy == "no-referrer") return "null"
        val source = sourceOrigin.toHttpUrlOrNull() ?: return "null"
        val same = sameOrigin(source, target)
        val httpsToHttp = source.scheme == "https" && target.scheme != "https"
        return when (policy) {
            "same-origin" -> if (same) sourceOrigin else "null"
            "no-referrer-when-downgrade",
            "strict-origin",
            "strict-origin-when-cross-origin" ->
                if (httpsToHttp) "null" else sourceOrigin
            else -> sourceOrigin
        }
    }

    /** Serializes an HTTP(S) URL's origin without path, query, fragment, or credentials. */
    private fun serializedOrigin(url: HttpUrl): String =
        url.newBuilder()
            .username("")
            .password("")
            .encodedPath("/")
            .query(null)
            .fragment(null)
            .build()
            .toString()
            .removeSuffix("/")

    private fun referrerForTarget(
        sourceValue: String?,
        policy: String,
        target: HttpUrl,
    ): String {
        if (sourceValue.isNullOrEmpty()) return ""
        val normalizedSource = sourceValue.lowercase(Locale.ROOT)
        if (!normalizedSource.startsWith("http://") &&
            !normalizedSource.startsWith("https://")
        ) return ""
        val parsed = sourceValue.toHttpUrlOrNull()
            ?.takeIf { it.scheme == "http" || it.scheme == "https" }
            ?: return ""
        val source = parsed.newBuilder()
            .username("")
            .password("")
            .fragment(null)
            .build()
        val origin = source.newBuilder()
            .encodedPath("/")
            .query(null)
            .fragment(null)
            .build()
            .toString()
        val full = source.toString().let {
            if (it.length > MAX_REFERRER_URL_LENGTH) origin else it
        }
        val same = sameOrigin(source, target)
        val downgrade = isPotentiallyTrustworthy(source) && !isPotentiallyTrustworthy(target)

        return when (policy) {
            "no-referrer" -> ""
            "no-referrer-when-downgrade" -> if (downgrade) "" else full
            "origin" -> origin
            "origin-when-cross-origin" -> if (same) full else origin
            "same-origin" -> if (same) full else ""
            "strict-origin" -> if (downgrade) "" else origin
            "strict-origin-when-cross-origin" -> when {
                same -> full
                downgrade -> ""
                else -> origin
            }
            "unsafe-url" -> full
            else -> ""
        }
    }

    private fun isPotentiallyTrustworthy(url: HttpUrl): Boolean {
        if (url.scheme == "https") return true
        val host = url.host.lowercase(Locale.ROOT).removeSurrounding("[", "]")
        if (host == "localhost" || host.endsWith(".localhost") || host == "::1") return true
        val parts = host.split('.')
        return parts.size == 4 &&
            parts.first() == "127" &&
            parts.all { part ->
                part.isNotEmpty() &&
                    part.all { it in '0'..'9' } &&
                    part.toIntOrNull()?.let { it in 0..255 } == true
            }
    }

    private fun sameOrigin(first: HttpUrl, second: HttpUrl): Boolean =
        first.scheme == second.scheme &&
            first.host == second.host &&
            first.port == second.port

    private fun mimeType(contentType: String?): String =
        contentType
            ?.substringBefore(';')
            ?.trim()
            ?.lowercase(Locale.ROOT)
            .orEmpty()

    private fun charsetName(contentType: String?): String? {
        val parameter = contentType
            ?.split(';')
            ?.firstOrNull {
                it.substringBefore('=').trim().equals("charset", ignoreCase = true)
            }
            ?.substringAfter('=', missingDelimiterValue = "")
            ?.trim()
            ?.trim('"', '\'')
            ?.takeIf { it.isNotEmpty() }
            ?: return null
        return try {
            Charset.forName(parameter).name()
        } catch (_: IllegalArgumentException) {
            parameter
        }
    }

    private val REDIRECT_CODES = setOf(301, 302, 303, 307, 308)
    private val POST_TO_GET_CODES = setOf(301, 302)
}
