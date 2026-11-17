package dev.pirc.pirc_mobile

import dev.pirc.android.core.Pairing
import dev.pirc.android.core.defaultHttpClient
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.Locale
import java.util.Base64
import java.util.concurrent.TimeUnit
import okhttp3.Call
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * Browser-style, bounded HTTP transport for document fetch/XHR and classic scripts.
 *
 * The caller must supply [sourceOrigin] from the native document session that owns the script
 * isolate. It is deliberately separate from [ResourceRequest], whose values come from JavaScript.
 * This class does not use NativeDocumentTransport: document navigations do not have CORS rules.
 */
internal class NativeScriptResourceTransport(
    private val pairing: Pairing?,
    client: OkHttpClient = sharedClient,
    private val responseLimit: Int = DEFAULT_RESPONSE_LIMIT,
    timeoutMillis: Long = DEFAULT_TIMEOUT_MILLIS,
    private val cookies: NativeDocumentCookies? = null,
    /** Script, fetch, stylesheet and image requests are page content unless the app says otherwise. */
    private val initiator: RequestInitiator = RequestInitiator.Content,
) {
    enum class Mode { CORS, NO_CORS, SAME_ORIGIN }
    enum class Credentials { OMIT, SAME_ORIGIN, INCLUDE }
    enum class Kind { FETCH, CLASSIC_SCRIPT, MODULE_SCRIPT, IMAGE, STYLESHEET }
    enum class Redirect { FOLLOW, ERROR, MANUAL }

    data class Header(val name: String, val value: String)

    data class ResourceRequest(
        val url: String,
        val method: String = "GET",
        val headers: List<Header> = emptyList(),
        val body: ByteArray? = null,
        val mode: Mode = Mode.CORS,
        val credentials: Credentials = Credentials.SAME_ORIGIN,
        val kind: Kind = Kind.FETCH,
        val redirect: Redirect = Redirect.FOLLOW,
        val crossOrigin: String? = null,
        val integrity: String? = null,
        val referrerPolicy: String? = null,
        val forcePreflight: Boolean = false,
        /** CSS import referrer; never changes the immutable document cookie/CORS initiator. */
        val stylesheetReferrerUrl: String? = null,
        /** Checked against the owning native session before transport dispatch. */
        val moduleReferrerUrl: String? = null,
    )

    data class ResourceResponse(
        val status: Int,
        val statusText: String,
        val url: String,
        val headers: Map<String, String>,
        val body: ByteArray?,
        /** `basic`, `cors`, `opaque`, or `script`. */
        val type: String,
        val redirected: Boolean = false,
        val mimeType: String = "",
        val charset: String? = null,
        val originClean: Boolean = true,
        val nativeCookieRequestKey: String = opaqueCookieRequestKey(null),
        val nativeSetCookieProcessed: Boolean = false,
        /** Host-only policy metadata for stylesheet imports; never a script-visible response header. */
        val stylesheetReferrerPolicy: String? = null,
        val moduleReferrerPolicy: String? = null,
    )

    companion object {
        private const val DEFAULT_RESPONSE_LIMIT = 2 * 1024 * 1024
        private const val DEFAULT_STYLESHEET_RESPONSE_LIMIT = 8 * 1024 * 1024
        private const val DEFAULT_REQUEST_LIMIT = 2 * 1024 * 1024
        private const val DEFAULT_TIMEOUT_MILLIS = 30_000L
        private const val MAX_REDIRECTS = 10

        private val sharedClient = defaultHttpClient()

        private val FORBIDDEN_METHODS = setOf("CONNECT", "TRACE", "TRACK")
        private val FORBIDDEN_HEADERS = setOf(
            "accept-charset", "accept-encoding", "access-control-request-headers",
            "access-control-request-method", "connection", "content-length", "cookie",
            "cookie2", "date", "dnt", "expect", "host", "keep-alive", "origin",
            "permissions-policy", "proxy-connection", "referer", "te", "trailer",
            "transfer-encoding", "upgrade", "via", "user-agent",
        )
        private val SAFELISTED_METHODS = setOf("GET", "HEAD", "POST")
        private val SAFELISTED_RESPONSE_HEADERS = setOf(
            "cache-control", "content-language", "content-length", "content-type",
            "expires", "last-modified", "pragma",
        )
        private val FORBIDDEN_RESPONSE_HEADERS = setOf("set-cookie", "set-cookie2")
        private val UNSAFE_REQUEST_HEADER_BYTES = Regex("[\\u0000-\\u0008\\u000A-\\u001F\\u007F\\\"():<>?@\\[\\]{}]")
        private val LANGUAGE_HEADER_BYTES = Regex("[^0-9A-Za-z *,-.;=]")
        private val TOKEN = Regex("^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
        private val SIMPLE_CONTENT_TYPES = setOf(
            "application/x-www-form-urlencoded", "multipart/form-data", "text/plain",
        )
        private val JAVASCRIPT_MIME_TYPES = setOf(
            "application/ecmascript", "application/javascript", "application/x-ecmascript",
            "application/x-javascript", "text/ecmascript", "text/javascript",
            "text/javascript1.0", "text/javascript1.1", "text/javascript1.2",
            "text/javascript1.3", "text/javascript1.4", "text/javascript1.5",
            "text/jscript", "text/livescript", "text/x-ecmascript", "text/x-javascript",
        )
        private val SUPPORTED_METHODS = setOf("GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS")
        private val REDIRECT_CODES = setOf(301, 302, 303, 307, 308)

        internal fun originForDocument(documentUrl: String, blobCreatorUrl: String? = null): String {
            if (!documentUrl.startsWith("blob:", ignoreCase = true)) {
                require(blobCreatorUrl == null) {
                    "A blob creator URL is only valid for a blob document"
                }
                return httpOriginForDocument(documentUrl, "Document URL")
            }

            val blobOrigin = originForBlobUrl(documentUrl)
            val creatorUrl = blobCreatorUrl
                ?: throw IllegalArgumentException("A blob document requires its creator URL")
            val creatorOrigin = if (creatorUrl.startsWith("blob:", ignoreCase = true)) {
                originForBlobUrl(creatorUrl)
            } else {
                httpOriginForDocument(creatorUrl, "Blob creator URL")
            }
            require(blobOrigin == creatorOrigin) {
                "Blob document origin does not match its creator origin"
            }
            return blobOrigin
        }

        /** Extracts the inherited HTTP(S) origin from one non-nested blob URL. */
        internal fun originForBlobUrl(blobUrl: String): String {
            require(blobUrl.startsWith("blob:", ignoreCase = true)) {
                "Blob URL must use the blob scheme"
            }
            val embeddedUrl = blobUrl.substring(5)
            require(!embeddedUrl.startsWith("blob:", ignoreCase = true)) {
                "Nested blob URLs are not supported"
            }
            val parsed = embeddedUrl.toHttpUrlOrNull()
                ?: throw IllegalArgumentException("Blob URL origin must be an absolute HTTP(S) URL")
            require(parsed.scheme == "http" || parsed.scheme == "https") {
                "Blob URL origin must use HTTP or HTTPS"
            }
            require(parsed.username.isEmpty() && parsed.password.isEmpty()) {
                "Blob URL origin must not contain credentials"
            }
            require(parsed.encodedPath != "/") {
                "Blob URL must contain an object identifier"
            }
            return buildString {
                append(parsed.newBuilder().encodedPath("/").query(null).fragment(null).build())
            }.removeSuffix("/")
        }

        private fun httpOriginForDocument(documentUrl: String, label: String): String {
            val parsed = documentUrl.toHttpUrlOrNull()
                ?: throw IllegalArgumentException("$label must be an absolute HTTP(S) URL")
            require(parsed.scheme == "http" || parsed.scheme == "https") {
                "$label must use HTTP or HTTPS"
            }
            require(parsed.username.isEmpty() && parsed.password.isEmpty()) {
                "$label must not contain credentials"
            }
            return buildString {
                append(parsed.newBuilder().encodedPath("/").query(null).fragment(null).build())
            }.removeSuffix("/")
        }
    }

    private val httpClient = client.newBuilder()
        .cookieJar(CookieJar.NO_COOKIES)
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
        .callTimeout(timeoutMillis, TimeUnit.MILLISECONDS)
        .build()
    private val pairingOrigin = pairing?.let { parseOrigin(it.baseUrl, "Pairing URL") }

    init {
        require(responseLimit >= 0) { "Script response limit must not be negative" }
        require(timeoutMillis > 0) { "Script request timeout must be positive" }
    }

    /** Makes one request using the document origin bound when its native script session opened. */
    fun load(
        sourceOrigin: String,
        request: ResourceRequest,
        baseUrl: String? = null,
        referrerUrl: String? = null,
        cancellation: NativeResourceCancellation? = null,
        initiatorUrl: String? = null,
        topLevelUrl: String? = null,
    ): ResourceResponse {
        cancellation?.throwIfCancelled()
        val source = parseOrigin(sourceOrigin, "Document origin")
        // A document served by the paired origin is inert: its content gets no same-origin script,
        // stylesheet or fetch resources and no scope of the paired origin (PairedOriginPolicy).
        require(pairingOrigin == null || source != pairingOrigin || initiator.mayCarry(pairing)) {
            "Documents served by the paired origin do not load script resources"
        }
        val cookieInitiator = nativeCookieContextUrl(initiatorUrl, source.toHttpUrlOrNull())
        val cookieTopLevel = nativeCookieContextUrl(topLevelUrl, cookieInitiator)
        val method = request.method.uppercase(Locale.ROOT)
        validateRequest(request, method)

        var url = resolveUrl(request.url, baseUrl)
        var body = request.body?.copyOf()
        val headers = linkedMapOf<String, Header>()
        request.headers.forEach { header ->
            val key = header.name.lowercase(Locale.ROOT)
            val previous = headers[key]
            headers[key] = if (previous == null) header else previous.copy(value = "${previous.value}, ${header.value}")
        }
        if (request.kind == Kind.STYLESHEET) {
            headers["accept"] = Header("Accept", "text/css,*/*;q=0.1")
        }
        var authorizationMayBeSent = true
        // Fetch taints the request origin once a redirect chain has crossed origins.
        var originIsTainted = false
        var corsRedirected = false
        var redirected = false
        var crossedCookieSiteBoundary = false
        var requestCookieKey = opaqueCookieRequestKey(null)
        var setCookieProcessed = false
        var currentMethod = method

        for (hop in 0..MAX_REDIRECTS) {
            cancellation?.throwIfCancelled()
            val crossOrigin = originOf(url) != source
            corsRedirected = corsRedirected || crossOrigin
            val mode = effectiveMode(request)
            val credentials = effectiveCredentials(request)
            val cookieContext = CookieRequestContext(
                initiatorUrl = cookieInitiator,
                topLevelUrl = cookieTopLevel,
                method = currentMethod,
                topLevelNavigation = false,
                credentialsEnabled = credentials != Credentials.OMIT &&
                    (credentials == Credentials.INCLUDE ||
                        (source != "null" && originOf(url) == source)),
                crossSiteRedirect = crossedCookieSiteBoundary,
            )
            if (mode == Mode.SAME_ORIGIN && crossOrigin) {
                throw IllegalArgumentException("Fetch mode same-origin rejected a cross-origin URL")
            }
            if (mode == Mode.NO_CORS) validateNoCorsRequest(currentMethod, headers.values)
            if (request.kind in setOf(Kind.CLASSIC_SCRIPT, Kind.STYLESHEET) &&
                !request.integrity.isNullOrBlank() && mode == Mode.NO_CORS && crossOrigin
            ) {
                throw IllegalArgumentException("Cross-origin resource integrity requires CORS permission")
            }

            val unsafeHeaderNames = headers.values
                .filterNot(::isSafelistedHeader)
                .map { it.name.lowercase(Locale.ROOT) }
                .toSet()
            val needsPreflight = mode == Mode.CORS && (crossOrigin || corsRedirected) &&
                (request.forcePreflight || currentMethod !in SAFELISTED_METHODS || unsafeHeaderNames.isNotEmpty())
            if (needsPreflight) {
                preflight(
                    url = url,
                    sourceOrigin = if (originIsTainted) "null" else source,
                    method = currentMethod,
                    headers = unsafeHeaderNames,
                    credentials = credentials,
                    cancellation = cancellation,
                )
            }

            val outgoing = Request.Builder().url(url)
            headers.values.forEach { outgoing.addHeader(it.name, it.value) }
            val cookiesApply = cookiesMayApply(initiator, pairing, pairingOrigin?.toHttpUrlOrNull(), url)
            val cookieHeader = if (cookiesApply) cookies?.requestHeader(url, cookieContext) else null
            requestCookieKey = opaqueCookieRequestKey(cookieHeader)
            cookieHeader?.let { outgoing.header("Cookie", it) }
            if ((currentMethod != "GET" && currentMethod != "HEAD") ||
                (mode == Mode.CORS && (crossOrigin || corsRedirected))
            ) {
                outgoing.header("Origin", if (originIsTainted) "null" else source)
            }
            val requestReferrer = if (request.kind == Kind.STYLESHEET) {
                request.stylesheetReferrerUrl ?: referrerUrl
            } else {
                referrerUrl
            }
            val referrerWithheld = pairingOrigin != null && !initiator.mayCarry(pairing) &&
                requestReferrer?.toHttpUrlOrNull()?.let { originOf(it) == pairingOrigin } == true &&
                originOf(url) != pairingOrigin
            requestReferrer?.takeUnless { referrerWithheld }
                ?.let { computeReferrer(it, url, request.referrerPolicy) }?.let {
                outgoing.header("Referer", it)
            }
            if (authorizationMayBeSent && initiator.mayCarry(pairing) && credentials != Credentials.OMIT &&
                source == pairingOrigin && originOf(url) == pairingOrigin
            ) {
                outgoing.header("Authorization", "Bearer ${checkNotNull(pairing).token}")
            }

            val requestBody = when (currentMethod) {
                "GET", "HEAD" -> null
                else -> body?.toRequestBody(null) ?: byteArrayOf().toRequestBody(null)
            }
            outgoing.method(currentMethod, requestBody)

            withCancellableCall(httpClient.newCall(outgoing.build()), cancellation) { response ->
                setCookieProcessed = (cookiesApply && receiveNativeSetCookies(
                    cookies,
                    url,
                    response,
                    cookieContext,
                )) || setCookieProcessed
                val location = response.header("Location")
                if (response.code in REDIRECT_CODES && location != null) {
                    if (request.redirect == Redirect.ERROR) {
                        throw IllegalStateException("Fetch redirect mode error rejected a redirect")
                    }
                    if (mode == Mode.CORS && corsRedirected) {
                        checkCorsResponse(response, source = if (originIsTainted) "null" else source,
                            credentials = credentials)
                    }
                    if (request.redirect == Redirect.MANUAL) {
                        return ResourceResponse(
                            0,
                            "",
                            "",
                            emptyMap(),
                            null,
                            "opaqueredirect",
                            nativeCookieRequestKey = requestCookieKey,
                            nativeSetCookieProcessed = setCookieProcessed,
                        )
                    }
                    check(hop < MAX_REDIRECTS) { "Too many script resource redirects" }
                    val target = url.resolve(location)
                        ?: throw IllegalArgumentException("Invalid script resource redirect URL")
                    validateUrl(target, "Script resource redirect URL")
                    if (!NativeDocumentCookies.schemefulSameSite(url, target)) {
                        crossedCookieSiteBoundary = true
                    }
                    val redirectCrossesOrigin = originOf(url) != originOf(target)
                    if (redirectCrossesOrigin) {
                        authorizationMayBeSent = false
                        headers.remove("authorization")
                        if (originOf(url) != source && originOf(url) != originOf(target)) {
                            originIsTainted = true
                        }
                    }
                    corsRedirected = corsRedirected || originOf(target) != source
                    if (response.code == 303 && currentMethod != "HEAD" ||
                        (response.code in setOf(301, 302) && currentMethod == "POST")
                    ) {
                        currentMethod = "GET"
                        body = null
                        headers.remove("content-type")
                    }
                    redirected = true
                    url = target
                    return@withCancellableCall null
                }

                if (mode == Mode.CORS && corsRedirected) {
                    checkCorsResponse(response, source = if (originIsTainted) "null" else source,
                        credentials = credentials)
                }

                val hasBody = currentMethod != "HEAD" && response.code !in setOf(204, 205, 304)
                val contentType = response.header("Content-Type")
                val mimeType = mimeType(contentType)
                val charset = charsetName(contentType)
                if (request.kind in setOf(Kind.CLASSIC_SCRIPT, Kind.MODULE_SCRIPT)) {
                    require(mimeType in JAVASCRIPT_MIME_TYPES) {
                        "Classic script response has an unsupported JavaScript MIME type"
                    }
                    require(response.code in 200..299) {
                        "Classic script request failed with HTTP ${response.code}"
                    }
                }
                if (request.kind == Kind.STYLESHEET) {
                    require(mimeType == "text/css") {
                        "Stylesheet response has an unsupported CSS MIME type"
                    }
                    require(response.code in 200..299) {
                        "Stylesheet request failed with HTTP ${response.code}"
                    }
                }
                val bodyLimit = if (request.kind == Kind.STYLESHEET) {
                    maxOf(responseLimit, DEFAULT_STYLESHEET_RESPONSE_LIMIT)
                } else {
                    responseLimit
                }
                val bytes = if (hasBody) readBounded(response.body?.byteStream(), bodyLimit) else null
                if (request.kind in setOf(Kind.CLASSIC_SCRIPT, Kind.MODULE_SCRIPT)) {
                    verifyIntegrity(bytes ?: byteArrayOf(), request.integrity, "Classic script")
                } else if (request.kind == Kind.STYLESHEET) {
                    verifyIntegrity(bytes ?: byteArrayOf(), request.integrity, "Stylesheet")
                }
                val resultType = when {
                    request.kind in setOf(Kind.CLASSIC_SCRIPT, Kind.MODULE_SCRIPT) -> "script"
                    request.kind == Kind.IMAGE -> "image"
                    request.kind == Kind.STYLESHEET -> "stylesheet"
                    !corsRedirected -> "basic"
                    mode == Mode.NO_CORS && request.kind == Kind.FETCH -> "opaque"
                    else -> "cors"
                }
                if (resultType == "opaque") {
                    return ResourceResponse(
                        0,
                        "",
                        "",
                        emptyMap(),
                        null,
                        "opaque",
                        nativeCookieRequestKey = requestCookieKey,
                        nativeSetCookieProcessed = setCookieProcessed,
                    )
                }
                val visibleHeaders = when {
                    !corsRedirected -> filteredHeaders(response.headers.toMultimap().mapValues { it.value.joinToString(", ") })
                    request.kind in setOf(Kind.CLASSIC_SCRIPT, Kind.IMAGE) && mode == Mode.NO_CORS -> emptyMap()
                    else -> corsHeaders(response.headers.toMultimap(), credentials)
                }
                return ResourceResponse(
                    status = response.code,
                    statusText = response.message,
                    url = url.toString(),
                    headers = visibleHeaders,
                    body = bytes,
                    type = resultType,
                    redirected = redirected,
                    mimeType = mimeType,
                    charset = charset,
                    originClean = !corsRedirected || mode == Mode.CORS,
                    nativeCookieRequestKey = requestCookieKey,
                    nativeSetCookieProcessed = setCookieProcessed,
                    stylesheetReferrerPolicy = if (request.kind == Kind.STYLESHEET) {
                        lastReferrerPolicy(response.headers.values("Referrer-Policy"))
                    } else null,
                    moduleReferrerPolicy = if (request.kind in setOf(Kind.CLASSIC_SCRIPT, Kind.MODULE_SCRIPT)) {
                        lastReferrerPolicy(response.headers.values("Referrer-Policy"))
                    } else null,
                )
            } ?: continue
        }
        error("Too many script resource redirects")
    }

    private inline fun <T> withCancellableCall(
        call: Call,
        cancellation: NativeResourceCancellation?,
        block: (Response) -> T,
    ): T {
        if (cancellation != null && !cancellation.attach(call)) {
            cancellation.throwIfCancelled()
        }
        try {
            cancellation?.throwIfCancelled()
            return call.execute().use { response ->
                cancellation?.throwIfCancelled()
                block(response)
            }
        } finally {
            cancellation?.detach(call)
        }
    }

    private fun validateRequest(request: ResourceRequest, method: String) {
        require(!request.forcePreflight || (request.kind == Kind.FETCH && request.mode == Mode.CORS)) {
            "Forced preflight requires a CORS data request"
        }
        require(method.matches(TOKEN) && method !in FORBIDDEN_METHODS) {
            "Fetch method is forbidden or invalid"
        }
        require(method in SUPPORTED_METHODS) { "Fetch method is not supported by the native transport" }
        require(method != "GET" && method != "HEAD" || request.body == null) {
            "$method requests cannot have a body"
        }
        require(request.body == null || request.body.size <= DEFAULT_REQUEST_LIMIT) {
            "Script request body exceeds 2 MiB"
        }
        if (request.kind == Kind.IMAGE) {
            require(method == "GET" && request.body == null && request.headers.isEmpty() && request.redirect == Redirect.FOLLOW) {
                "Image requests must use GET without body or custom headers and follow redirects"
            }
            require(request.crossOrigin == null || request.crossOrigin in setOf("", "anonymous", "use-credentials")) {
                "Invalid image crossorigin value"
            }
        }
        if (request.kind in setOf(Kind.CLASSIC_SCRIPT, Kind.MODULE_SCRIPT)) {
            require(method == "GET" && request.body == null) { "Classic script requests must use GET without a body" }
            require(request.crossOrigin == null || request.crossOrigin in setOf("", "anonymous", "use-credentials")) {
                "Invalid classic script crossorigin value"
            }
            require(request.integrity.isNullOrBlank() || request.integrity.length <= 4096) {
                "Classic script integrity metadata is too large"
            }
        }
        require(request.moduleReferrerUrl == null || request.kind == Kind.MODULE_SCRIPT) {
            "Module referrer metadata is only valid for module requests"
        }
        if (request.kind == Kind.MODULE_SCRIPT) {
            require(request.headers.isEmpty() && request.redirect == Redirect.FOLLOW && !request.forcePreflight) {
                "Module requests must use GET without custom headers and follow redirects"
            }
        }
        require(request.stylesheetReferrerUrl == null || request.kind == Kind.STYLESHEET) {
            "Stylesheet referrer metadata is only valid for stylesheet requests"
        }
        if (request.kind == Kind.STYLESHEET) {
            require(method == "GET" && request.body == null && request.headers.isEmpty() &&
                request.redirect == Redirect.FOLLOW && !request.forcePreflight
            ) { "Stylesheet requests must use GET without a body or custom headers and follow redirects" }
            require(request.crossOrigin == null || request.crossOrigin in setOf("", "anonymous", "use-credentials")) {
                "Invalid stylesheet crossorigin value"
            }
            require(request.integrity.isNullOrBlank() || request.integrity.length <= 4096) {
                "Stylesheet integrity metadata is too large"
            }
        }
        require(request.referrerPolicy == null || request.referrerPolicy.isEmpty() ||
            request.referrerPolicy in REFERRER_POLICIES
        ) {
            "Unsupported referrer policy"
        }
        val names = mutableSetOf<String>()
        request.headers.forEach { header ->
            val name = header.name.lowercase(Locale.ROOT)
            require(TOKEN.matches(header.name)) { "Invalid fetch request header name" }
            require(
                name !in FORBIDDEN_HEADERS && !name.startsWith("proxy-") && !name.startsWith("sec-") &&
                    !name.startsWith("x-pirc-"),
            ) {
                "Fetch request header is forbidden: ${header.name}"
            }
            require('\r' !in header.value && '\n' !in header.value && '\u0000' !in header.value) {
                "Fetch request header value contains a forbidden character"
            }
            require(header.value.toByteArray(Charsets.UTF_8).size <= 8 * 1024) {
                "Fetch request header value is too large"
            }
            names += name
        }
    }

    private fun effectiveCredentials(request: ResourceRequest): Credentials = when (request.kind) {
        Kind.FETCH -> request.credentials
        Kind.IMAGE -> when (request.crossOrigin) {
            null, "use-credentials" -> Credentials.INCLUDE
            "", "anonymous" -> Credentials.SAME_ORIGIN
            else -> throw IllegalArgumentException("Invalid image crossorigin value")
        }
        Kind.CLASSIC_SCRIPT, Kind.MODULE_SCRIPT -> when (request.crossOrigin) {
            null, "", "anonymous" -> Credentials.SAME_ORIGIN
            "use-credentials" -> Credentials.INCLUDE
            else -> throw IllegalArgumentException("Invalid classic script crossorigin value")
        }
        Kind.STYLESHEET -> when (request.crossOrigin) {
            null, "use-credentials" -> Credentials.INCLUDE
            "", "anonymous" -> Credentials.SAME_ORIGIN
            else -> throw IllegalArgumentException("Invalid stylesheet crossorigin value")
        }
    }

    private fun effectiveMode(request: ResourceRequest): Mode = when (request.kind) {
        Kind.FETCH -> request.mode
        Kind.MODULE_SCRIPT -> Mode.CORS
        Kind.CLASSIC_SCRIPT, Kind.IMAGE, Kind.STYLESHEET ->
            if (request.crossOrigin == null) Mode.NO_CORS else Mode.CORS
    }

    private fun validateNoCorsRequest(method: String, headers: Collection<Header>) {
        require(method in SAFELISTED_METHODS) {
            "no-cors fetch only supports GET, HEAD, or POST"
        }
        require(headers.all(::isSafelistedHeader)) {
            "no-cors fetch cannot use a non-safelisted request header"
        }
    }

    private fun isSafelistedHeader(header: Header): Boolean {
        val name = header.name.lowercase(Locale.ROOT)
        val value = header.value
        if (value.toByteArray(Charsets.UTF_8).size > 128) return false
        if (UNSAFE_REQUEST_HEADER_BYTES.containsMatchIn(value)) return false
        return when (name) {
            "accept" -> true
            "accept-language", "content-language" -> !LANGUAGE_HEADER_BYTES.containsMatchIn(value)
            "content-type" -> value.substringBefore(';').trim().lowercase(Locale.ROOT) in SIMPLE_CONTENT_TYPES
            "range" -> value.matches(Regex("^bytes=[0-9]+-[0-9]*$"))
            else -> false
        }
    }

    private fun preflight(
        url: HttpUrl,
        sourceOrigin: String,
        method: String,
        headers: Set<String>,
        credentials: Credentials,
        cancellation: NativeResourceCancellation?,
    ) {
        cancellation?.throwIfCancelled()
        val requestedHeaderNames = headers.sorted()
        val requestedHeaders = requestedHeaderNames.joinToString(", ")
        val builder = Request.Builder()
            .url(url)
            .header("Origin", sourceOrigin)
            .header("Access-Control-Request-Method", method)
        if (requestedHeaders.isNotEmpty()) {
            builder.header("Access-Control-Request-Headers", requestedHeaders)
        }
        builder.method("OPTIONS", byteArrayOf().toRequestBody(null))
        withCancellableCall(httpClient.newCall(builder.build()), cancellation) { response ->
            check(response.code in 200..299) { "CORS preflight failed with HTTP ${response.code}" }
            checkCorsResponse(response, sourceOrigin, credentials)
            val allowedMethods = response.headers.values("Access-Control-Allow-Methods")
                .flatMap(::commaSeparatedTokens).map { it.uppercase(Locale.ROOT) }.toSet()
            val methodAllowed = method in SAFELISTED_METHODS || method in allowedMethods ||
                ("*" in allowedMethods && credentials != Credentials.INCLUDE)
            check(methodAllowed) { "CORS preflight did not allow method $method" }
            if (requestedHeaders.isNotEmpty()) {
                val allowedHeaders = response.headers.values("Access-Control-Allow-Headers")
                    .flatMap(::commaSeparatedTokens).map { it.lowercase(Locale.ROOT) }.toSet()
                val headerAllowed = requestedHeaderNames.all { name ->
                    name in allowedHeaders ||
                        (name != "authorization" && "*" in allowedHeaders && credentials != Credentials.INCLUDE)
                }
                check(headerAllowed) { "CORS preflight did not allow the requested headers" }
            }
        }
    }

    private fun checkCorsResponse(
        response: okhttp3.Response,
        source: String,
        credentials: Credentials,
    ) {
        val allowedOrigins = response.headers.values("Access-Control-Allow-Origin")
        check(allowedOrigins.size == 1) { "CORS response must contain one Access-Control-Allow-Origin header" }
        val allowedOrigin = allowedOrigins.single().trim()
        val credentialed = credentials == Credentials.INCLUDE
        check(allowedOrigin == source || (allowedOrigin == "*" && !credentialed)) {
            "CORS response did not allow this document origin"
        }
        if (credentialed) {
            check(response.header("Access-Control-Allow-Credentials") == "true") {
                "Credentialed CORS response must allow credentials"
            }
        }
    }

    private fun corsHeaders(
        headers: Map<String, List<String>>,
        credentials: Credentials,
    ): Map<String, String> {
        val expose = headers.entries
            .filter { it.key.equals("Access-Control-Expose-Headers", true) }
            .flatMap { it.value }
            .flatMap(::commaSeparatedTokens)
            .map { it.lowercase(Locale.ROOT) }
            .toSet()
        val wildcard = "*" in expose && credentials != Credentials.INCLUDE
        return filteredHeaders(headers.mapValues { it.value.joinToString(", ") })
            .filterKeys { name ->
                val lower = name.lowercase(Locale.ROOT)
                lower in SAFELISTED_RESPONSE_HEADERS || lower in expose || wildcard
            }
    }

    private fun filteredHeaders(headers: Map<String, String>): Map<String, String> =
        headers.filterKeys { it.lowercase(Locale.ROOT) !in FORBIDDEN_RESPONSE_HEADERS }

    private fun readBounded(input: java.io.InputStream?, limit: Int): ByteArray {
        if (input == null) return byteArrayOf()
        val output = ByteArrayOutputStream()
        input.use {
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = it.read(buffer)
                if (count < 0) break
                check(output.size().toLong() + count <= limit.toLong()) {
                    "Script resource response exceeds the configured size limit"
                }
                output.write(buffer, 0, count)
            }
        }
        return output.toByteArray()
    }

    private fun verifyIntegrity(bytes: ByteArray, metadata: String?, subject: String) {
        if (metadata.isNullOrBlank()) return
        val supported = metadata.trim().split(Regex("\\s+")).mapNotNull { token ->
            val fields = token.split('-', limit = 2)
            if (fields.size != 2) return@mapNotNull null
            val algorithm = fields[0]
            val digest = fields[1].substringBefore('?')
            val rank = when (algorithm) {
                "sha256" -> 1
                "sha384" -> 2
                "sha512" -> 3
                else -> return@mapNotNull null
            }
            val decoded = runCatching { Base64.getDecoder().decode(digest) }.getOrNull()
                ?: return@mapNotNull null
            val expectedSize = when (rank) { 1 -> 32; 2 -> 48; else -> 64 }
            if (decoded.size != expectedSize) return@mapNotNull null
            Triple(rank, algorithm, decoded)
        }
        require(supported.isNotEmpty()) { "$subject integrity metadata has no supported digest" }
        val strongestRank = supported.maxOf { it.first }
        val strongest = supported.filter { it.first == strongestRank }
        val matched = strongest.any { (_, algorithm, expected) ->
            val jcaName = when (algorithm) {
                "sha256" -> "SHA-256"
                "sha384" -> "SHA-384"
                else -> "SHA-512"
            }
            MessageDigest.isEqual(expected, MessageDigest.getInstance(jcaName).digest(bytes))
        }
        require(matched) { "$subject integrity check failed" }
    }

    private fun lastReferrerPolicy(values: List<String>): String? = values
        .flatMap { it.split(',') }
        .map { it.trim().lowercase(Locale.ROOT) }
        .lastOrNull { it in REFERRER_POLICIES }

    private fun computeReferrer(referrer: String, target: HttpUrl, policyValue: String?): String? {
        val source = referrer.toHttpUrlOrNull()?.let(::validateUrl) ?: return null
        val policy = policyValue?.takeIf(String::isNotEmpty) ?: "strict-origin-when-cross-origin"
        val withoutCredentials = source.newBuilder().username("").password("").fragment(null).build()
        val sameOrigin = originOf(withoutCredentials) == originOf(target)
        val downgrade = withoutCredentials.scheme == "https" && target.scheme == "http"
        val full = withoutCredentials.toString()
        val origin = "${originOf(withoutCredentials)}/"
        return when (policy) {
            "no-referrer" -> null
            "no-referrer-when-downgrade" -> if (downgrade) null else full
            "origin" -> origin
            "origin-when-cross-origin" -> if (sameOrigin) full else origin
            "same-origin" -> if (sameOrigin) full else null
            "strict-origin" -> if (downgrade) null else origin
            "strict-origin-when-cross-origin" -> when {
                sameOrigin -> full
                downgrade -> null
                else -> origin
            }
            "unsafe-url" -> full
            else -> null
        }
    }

    private fun parseUrl(value: String, label: String): HttpUrl {
        val url = value.toHttpUrlOrNull() ?: throw IllegalArgumentException("$label must be an absolute HTTP(S) URL")
        return validateUrl(url, label)
    }

    private fun resolveUrl(value: String, baseUrl: String?): HttpUrl {
        val absolute = value.toHttpUrlOrNull()
        val url = if (absolute != null) absolute else {
            val base = baseUrl?.let { parseUrl(it, "Document URL") }
                ?: throw IllegalArgumentException("Script resource URL must be absolute")
            base.resolve(value) ?: throw IllegalArgumentException("Invalid script resource URL")
        }
        return validateUrl(url, "Script resource URL")
    }

    private fun parseOrigin(value: String, label: String): String {
        if (value == "null") return value
        return originOf(parseUrl(value, label))
    }

    private fun validateUrl(url: HttpUrl, label: String): HttpUrl {
        require(url.scheme == "http" || url.scheme == "https") { "$label must use HTTP or HTTPS" }
        require(url.username.isEmpty() && url.password.isEmpty()) { "$label must not contain credentials" }
        return url
    }

    private fun originOf(url: HttpUrl): String = url.newBuilder()
        .encodedPath("/")
        .query(null)
        .fragment(null)
        .build()
        .toString()
        .removeSuffix("/")

    private fun validateUrl(url: HttpUrl): HttpUrl {
        require(url.scheme == "http" || url.scheme == "https") {
            "Referrer URL must use HTTP or HTTPS"
        }
        return url
    }

    private fun mimeType(contentType: String?): String = contentType
        ?.substringBefore(';')
        ?.trim()
        ?.lowercase(Locale.ROOT)
        .orEmpty()

    private fun charsetName(contentType: String?): String? {
        val raw = contentType?.split(';')?.firstOrNull {
            it.substringBefore('=').trim().equals("charset", ignoreCase = true)
        }?.substringAfter('=', "")?.trim()?.trim('"', '\'')?.takeIf(String::isNotEmpty)
            ?: return null
        return runCatching { java.nio.charset.Charset.forName(raw).name() }.getOrDefault(raw)
    }

    private fun commaSeparatedTokens(value: String): List<String> =
        value.split(',').map(String::trim).filter(String::isNotEmpty)

    private val REFERRER_POLICIES = setOf(
        "no-referrer", "no-referrer-when-downgrade", "origin", "origin-when-cross-origin",
        "same-origin", "strict-origin", "strict-origin-when-cross-origin", "unsafe-url",
    )
}
