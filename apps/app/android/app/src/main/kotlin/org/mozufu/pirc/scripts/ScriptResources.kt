package org.mozufu.pirc.scripts

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import java.net.SocketAddress
import javax.net.SocketFactory
import java.util.concurrent.TimeUnit
import okhttp3.Authenticator
import okhttp3.Call
import okhttp3.CookieJar
import okhttp3.Dns
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

/**
 * Network requests of a message document's script (`fetch`, `XMLHttpRequest`, `<script src>`,
 * stylesheets), and the bytes of a media element the user tapped.
 *
 * A message document has an opaque origin, so every request is cross-origin and goes out with
 * no credentials: this client has no cookie jar, no authenticator, no cache and no interceptor,
 * and it never sees the device token. A script may not set `Authorization`, `Cookie` or
 * `Proxy-Authorization`. Requests carry `Origin: null` and no `Referer`. Only absolute
 * `http`/`https` URLs are allowed (an opaque document has no base URL), and only to public
 * addresses: a message cannot reach the Gateway's tailnet, the local network or this device.
 * The address is checked three times: numeric hosts in the URL (non-canonical forms such as
 * `127.1` or `2130706433` are refused outright), every name lookup ([PolicyDns]), and every
 * socket connect ([PolicySocketFactory]), which also covers each redirect hop.
 * Images are not loaded for scripts: remote images load only after the user taps them.
 *
 * Known gap, left as it is: the body of an opaque (`no-cors`) classic script or stylesheet
 * reaches the isolate so the runtime can run or apply it, as a browser does. The runtime must
 * keep it from the page's own script.
 */
class ScriptResources(
    private val addressPolicy: (InetAddress) -> Boolean = ::isPublicAddress,
    client: OkHttpClient? = null,
    private val responseLimit: Int = RESPONSE_LIMIT,
) {
    private val client: OkHttpClient = (client?.newBuilder() ?: OkHttpClient.Builder())
        .cookieJar(CookieJar.NO_COOKIES)
        .authenticator(Authenticator.NONE)
        .proxyAuthenticator(Authenticator.NONE)
        .cache(null)
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
        .dns(PolicyDns(addressPolicy))
        // A proxy would resolve the name itself, past the address policy.
        .proxy(Proxy.NO_PROXY)
        // The last check: a literal the URL check missed still cannot connect.
        .socketFactory(PolicySocketFactory(addressPolicy))
        .callTimeout(TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .apply {
            interceptors().clear()
            networkInterceptors().clear()
        }
        .build()

    enum class Kind { FETCH, SCRIPT, MODULE, STYLESHEET }
    enum class Mode { CORS, NO_CORS }
    enum class Redirect { FOLLOW, ERROR, MANUAL }

    data class ResourceRequest(
        val url: String,
        val method: String = "GET",
        val headers: List<Pair<String, String>> = emptyList(),
        val body: ByteArray? = null,
        val kind: Kind = Kind.FETCH,
        val mode: Mode = Mode.CORS,
        val redirect: Redirect = Redirect.FOLLOW,
    )

    /**
     * The requests of one document in flight, so closing the document can cancel them. A
     * request ID is in use from [begin] to [end], across its preflight and redirect hops, even
     * after it is cancelled: its thread is busy until [end]. A second request with the same ID
     * is refused, so the cap of [MAX_IN_FLIGHT] holds, and so does the thread budget of
     * `ScriptsChannel.NETWORK_THREADS`.
     */
    class Calls {
        /** One reserved request ID: its HTTP calls, and whether it was cancelled. */
        private class Reservation {
            val calls = HashSet<Call>()
            var cancelled = false

            fun cancel() {
                cancelled = true
                calls.forEach { it.cancel() }
            }
        }

        private val active = HashMap<String, Reservation>()
        private var closed = false

        /** Reserves [id] for one request. */
        @Synchronized
        fun begin(id: String) {
            require(REQUEST_ID.matches(id)) { "Invalid request ID" }
            if (closed) throw ScriptFailure("SCRIPT_CLOSED", "The document closed.")
            if (id in active) throw ScriptFailure("RESOURCE", "The request ID $id is already in use.")
            if (active.size >= MAX_IN_FLIGHT) {
                throw ScriptFailure("RESOURCE", "A document may have at most $MAX_IN_FLIGHT requests at once.")
            }
            active[id] = Reservation()
        }

        @Synchronized
        fun end(id: String) {
            active.remove(id)
        }

        /** Tracks one HTTP call (the request, its preflight or a redirect hop) of [id]. */
        @Synchronized
        internal fun register(id: String, call: Call) {
            val reservation = active[id]
            if (closed || reservation == null || reservation.cancelled) {
                call.cancel()
                throw ScriptFailure(if (closed) "SCRIPT_CLOSED" else "RESOURCE", "The request was cancelled.")
            }
            reservation.calls += call
        }

        @Synchronized
        internal fun done(id: String, call: Call) {
            active[id]?.calls?.remove(call)
        }

        /** Cancels the request [id] with its preflight; the ID stays reserved until it ends. */
        @Synchronized
        fun cancel(id: String) {
            active[id]?.cancel()
        }

        /** Cancels every request; later ones are allowed once the cancelled ones end. */
        @Synchronized
        fun cancelAll() {
            active.values.forEach { it.cancel() }
        }

        /** Cancels every request and refuses new ones (the document closed). */
        @Synchronized
        fun close() {
            closed = true
            cancelAll()
        }
    }

    /** Runs [action] with [requestId] reserved in [calls]. */
    private inline fun <T> reserved(calls: Calls, requestId: String, action: () -> T): T {
        calls.begin(requestId)
        try {
            return action()
        } finally {
            calls.end(requestId)
        }
    }

    /**
     * Loads [request] for a document whose requests are tracked by [calls] under [requestId].
     * Returns the response as the script may see it (the wire format of the `resource` method).
     */
    fun load(request: ResourceRequest, calls: Calls, requestId: String): Map<String, Any?> =
        reserved(calls, requestId) { loadReserved(request, calls, requestId) }

    private fun loadReserved(request: ResourceRequest, calls: Calls, requestId: String): Map<String, Any?> {
        val method = request.method.uppercase()
        require(method in METHODS) { "Unsupported request method" }
        if (request.mode == Mode.NO_CORS) {
            require(method in SIMPLE_METHODS) { "A no-cors request must be GET, HEAD or POST" }
        }
        if (request.kind == Kind.MODULE) require(request.mode == Mode.CORS) { "Module scripts need CORS" }
        require(request.body == null || request.body.size <= REQUEST_LIMIT) { "The request body exceeds 2 MiB" }
        require(request.body == null || method !in setOf("GET", "HEAD")) { "GET and HEAD have no body" }
        var headers = checkedHeaders(request.headers)
        val simple = method in SIMPLE_METHODS && headers.all { (name, value) -> safelisted(name, value) }
        if (request.mode == Mode.NO_CORS && !simple) {
            throw ScriptFailure("RESOURCE", "A no-cors request may only use safelisted headers.")
        }
        var url = checkedUrl(request.url)
        var currentMethod = method
        var body = request.body
        var redirected = false
        repeat(MAX_REDIRECTS + 1) {
            if (request.mode == Mode.CORS && !simple) preflight(url, currentMethod, headers, calls, requestId)
            val builder = Request.Builder().url(url).header("Origin", "null")
            for ((name, value) in headers) builder.addHeader(name, value)
            val requestBody = body?.toRequestBody(null)
            builder.method(currentMethod, requestBody ?: if (currentMethod in BODY_METHODS) ByteArray(0).toRequestBody(null) else null)
            execute(builder.build(), calls, requestId) { response ->
                if (response.code in REDIRECT_CODES && response.header("Location") != null) {
                    if (request.mode == Mode.CORS) checkCors(response)
                    when (request.redirect) {
                        Redirect.ERROR -> throw ScriptFailure("RESOURCE", "The request was redirected.")
                        Redirect.MANUAL -> return opaqueRedirect(url)
                        Redirect.FOLLOW -> Unit
                    }
                    val next = url.resolve(response.header("Location")!!)
                        ?: throw ScriptFailure("RESOURCE", "The redirect location is not an HTTP URL.")
                    url = checkedUrl(next.toString())
                    if (response.code == 303 && currentMethod != "HEAD" ||
                        response.code in setOf(301, 302) && currentMethod == "POST"
                    ) {
                        currentMethod = "GET"
                        body = null
                        // The body is gone, and so are the headers that described it.
                        headers = headers.filterNot { (name) -> name.lowercase() in BODY_HEADERS }
                    }
                    redirected = true
                    return@repeat
                }
                return respond(request, response, url, redirected)
            }
        }
        throw ScriptFailure("RESOURCE", "Too many redirects.")
    }

    /** The bytes of a media element the user tapped: `{bytes, mimeType}`. */
    fun media(url: String, calls: Calls, requestId: String): Map<String, Any?> =
        reserved(calls, requestId) { mediaReserved(url, calls, requestId) }

    private fun mediaReserved(url: String, calls: Calls, requestId: String): Map<String, Any?> {
        var target = checkedUrl(url)
        repeat(MAX_REDIRECTS + 1) {
            execute(Request.Builder().url(target).get().build(), calls, requestId) { response ->
                val location = response.header("Location")
                if (response.code in REDIRECT_CODES && location != null) {
                    // Each hop is checked again: a redirect cannot lead to a private address.
                    target = checkedUrl(
                        target.resolve(location)?.toString()
                            ?: throw ScriptFailure("RESOURCE", "The redirect location is not an HTTP URL."),
                    )
                    return@repeat
                }
                if (!response.isSuccessful) throw ScriptFailure("RESOURCE", "The media request failed (${response.code}).")
                val bytes = readBounded(response, MEDIA_LIMIT)
                val type = response.body.contentType()
                return mapOf("bytes" to bytes, "mimeType" to (type?.let { "${it.type}/${it.subtype}" } ?: ""))
            }
        }
        throw ScriptFailure("RESOURCE", "Too many redirects.")
    }

    /**
     * [absoluteUrl], and an IP address written in the URL must pass the address policy too:
     * the client looks up names only, so a literal like `127.0.0.1` never reaches [PolicyDns].
     * A numeric host that is not a canonical dotted quad (`127.1`, `2130706433`, `0177.0.0.1`,
     * `127.0.0.1.`) is refused: resolvers read those forms differently.
     */
    private fun checkedUrl(value: String): HttpUrl {
        val url = absoluteUrl(value)
        val host = url.host
        if (NUMERIC_HOST.matches(host) && !CANONICAL_IPV4.matches(host)) {
            throw ScriptFailure("RESOURCE", "$host is not a canonical address.")
        }
        if (host.contains(':') || CANONICAL_IPV4.matches(host)) {
            // getByName parses a literal without any lookup.
            if (!addressPolicy(InetAddress.getByName(host))) {
                throw ScriptFailure("RESOURCE", "$host is not a public address.")
            }
        }
        return url
    }

    private fun preflight(url: HttpUrl, method: String, headers: List<Pair<String, String>>, calls: Calls, id: String) {
        val names = headers.filterNot { (name, value) -> safelisted(name, value) }
            .map { it.first.lowercase() }.distinct().sorted()
        val request = Request.Builder().url(url).method("OPTIONS", null)
            .header("Origin", "null")
            .header("Access-Control-Request-Method", method)
            .apply { if (names.isNotEmpty()) header("Access-Control-Request-Headers", names.joinToString(",")) }
            .build()
        // Tracked under the request's own ID, so cancelling the request cancels it too.
        execute(request, calls, id) { response ->
            if (response.code !in 200..299) throw ScriptFailure("RESOURCE", "The CORS preflight failed.")
            checkCors(response)
            val methods = tokens(response.header("Access-Control-Allow-Methods"))
            if (method !in SIMPLE_METHODS && "*" !in methods && method !in methods.map { it.uppercase() }) {
                throw ScriptFailure("RESOURCE", "The CORS preflight does not allow $method.")
            }
            val allowed = tokens(response.header("Access-Control-Allow-Headers")).map { it.lowercase() }
            if ("*" !in allowed && names.any { it !in allowed }) {
                throw ScriptFailure("RESOURCE", "The CORS preflight does not allow the request headers.")
            }
        }
    }

    /**
     * Runs [request] and hands its response to [read], then closes it. The call stays tracked
     * until [read] ends, so a cancel also stops a body that is still arriving.
     */
    private inline fun <T> execute(request: Request, calls: Calls, id: String, read: (Response) -> T): T {
        val call = client.newCall(request)
        calls.register(id, call)
        try {
            return call.execute().use(read)
        } catch (error: IOException) {
            throw ScriptFailure("RESOURCE", if (call.isCanceled()) "The request was cancelled." else "The request failed.")
        } finally {
            calls.done(id, call)
        }
    }

    private fun respond(request: ResourceRequest, response: Response, url: HttpUrl, redirected: Boolean): Map<String, Any?> {
        val type = response.body.contentType()
        val mimeType = type?.let { "${it.type}/${it.subtype}" } ?: ""
        if (request.mode == Mode.NO_CORS) {
            // An opaque response: the script learns nothing about it. A classic script or a
            // stylesheet is still handed to the runtime, which runs or applies it without
            // exposing its text, as a browser does.
            val content = request.kind == Kind.SCRIPT || request.kind == Kind.STYLESHEET
            return mapOf(
                "status" to if (content) response.code else 0, "statusText" to "", "url" to if (content) url.toString() else "",
                "headers" to emptyList<Any>(), "bodyBytes" to if (content && response.isSuccessful) readBounded(response, limitFor(request)) else null,
                "type" to "opaque", "redirected" to false, "mimeType" to if (content) mimeType else "",
                "charset" to if (content) type?.charset()?.name() else null, "originClean" to false,
            )
        }
        checkCors(response)
        val exposed = tokens(response.header("Access-Control-Expose-Headers")).map { it.lowercase() }.toSet()
        val headers = response.headers.names()
            .filter { val name = it.lowercase(); name !in FORBIDDEN_RESPONSE_HEADERS && (name in SAFELISTED_RESPONSE_HEADERS || name in exposed || "*" in exposed) }
            .sortedBy { it.lowercase() }
            .map { listOf(it.lowercase(), response.headers(it).joinToString(", ")) }
        return mapOf(
            "status" to response.code, "statusText" to response.message, "url" to url.toString(),
            "headers" to headers, "bodyBytes" to if (request.method.uppercase() == "HEAD") ByteArray(0) else readBounded(response, limitFor(request)),
            "type" to "cors", "redirected" to redirected, "mimeType" to mimeType,
            "charset" to type?.charset()?.name(), "originClean" to true,
        )
    }

    private fun opaqueRedirect(url: HttpUrl) = mapOf(
        "status" to 0, "statusText" to "", "url" to url.toString(), "headers" to emptyList<Any>(),
        "bodyBytes" to null, "type" to "opaqueredirect", "redirected" to false, "mimeType" to "",
        "charset" to null, "originClean" to false,
    )

    /** Without credentials, `*` or the opaque origin `null` allows the read. */
    private fun checkCors(response: Response) {
        val allowed = response.header("Access-Control-Allow-Origin")?.trim()
        if (allowed != "*" && allowed != "null") {
            throw ScriptFailure("RESOURCE", "The response does not allow cross-origin reads (CORS).")
        }
    }

    private fun limitFor(request: ResourceRequest) =
        if (request.kind == Kind.STYLESHEET) maxOf(responseLimit, STYLESHEET_LIMIT) else responseLimit

    private fun readBounded(response: Response, limit: Int): ByteArray {
        val declared = response.body.contentLength()
        if (declared > limit) throw ScriptFailure("RESOURCE", "The response is larger than ${limit / 1024 / 1024} MiB.")
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        response.body.byteStream().use { input ->
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                if (out.size() + read > limit) throw ScriptFailure("RESOURCE", "The response is larger than ${limit / 1024 / 1024} MiB.")
                out.write(buffer, 0, read)
            }
        }
        return out.toByteArray()
    }

    private fun checkedHeaders(headers: List<Pair<String, String>>): List<Pair<String, String>> {
        require(headers.size <= MAX_HEADERS) { "Too many request headers" }
        for ((name, value) in headers) {
            require(TOKEN.matches(name)) { "Invalid request header name" }
            require(value.none { it == '\r' || it == '\n' || it.code == 0 }) { "Invalid request header value" }
            val lower = name.lowercase()
            if (lower in CREDENTIAL_HEADERS) {
                throw ScriptFailure("RESOURCE", "A message document cannot send $name.")
            }
        }
        // Forbidden request headers are the browser's to set; a script's value is dropped.
        return headers.filter { (name) ->
            val lower = name.lowercase()
            lower !in FORBIDDEN_HEADERS && !lower.startsWith("proxy-") && !lower.startsWith("sec-")
        }
    }

    private fun safelisted(name: String, value: String): Boolean = when (name.lowercase()) {
        "accept", "accept-language", "content-language" -> value.length <= 128 && value.none { it.code < 0x20 && it != '\t' }
        "content-type" -> value.substringBefore(';').trim().lowercase() in SIMPLE_CONTENT_TYPES
        else -> false
    }

    private fun tokens(value: String?): List<String> =
        value?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() } ?: emptyList()

    /** Sockets that refuse to connect to an address the policy does not allow. */
    internal class PolicySocketFactory(private val allowed: (InetAddress) -> Boolean) : SocketFactory() {
        private fun checked(address: InetAddress): InetAddress {
            if (!allowed(address)) throw IOException("${address.hostAddress} is not a public address")
            return address
        }

        override fun createSocket(): Socket = object : Socket() {
            override fun connect(endpoint: SocketAddress?, timeout: Int) {
                val target = endpoint as? InetSocketAddress ?: throw IOException("Unsupported address")
                val address = target.address ?: throw IOException("Unresolved address")
                checked(address)
                super.connect(endpoint, timeout)
            }

            override fun connect(endpoint: SocketAddress?) = connect(endpoint, 0)
        }

        override fun createSocket(host: String, port: Int): Socket =
            createSocket().apply { connect(InetSocketAddress(host, port)) }

        override fun createSocket(host: String, port: Int, localHost: InetAddress?, localPort: Int): Socket =
            createSocket().apply {
                bind(InetSocketAddress(localHost, localPort))
                connect(InetSocketAddress(host, port))
            }

        override fun createSocket(host: InetAddress, port: Int): Socket =
            createSocket().apply { connect(InetSocketAddress(checked(host), port)) }

        override fun createSocket(address: InetAddress, port: Int, localAddress: InetAddress?, localPort: Int): Socket =
            createSocket().apply {
                bind(InetSocketAddress(localAddress, localPort))
                connect(InetSocketAddress(checked(address), port))
            }
    }

    private class PolicyDns(private val allowed: (InetAddress) -> Boolean) : Dns {
        override fun lookup(hostname: String): List<InetAddress> {
            val addresses = Dns.SYSTEM.lookup(hostname)
            // Every address must be allowed, so DNS cannot point one name at both.
            if (addresses.isEmpty() || !addresses.all(allowed)) {
                throw java.net.UnknownHostException("$hostname is not a public address")
            }
            return addresses
        }
    }

    companion object {
        const val RESPONSE_LIMIT = 2 * 1024 * 1024
        const val STYLESHEET_LIMIT = 8 * 1024 * 1024
        const val REQUEST_LIMIT = 2 * 1024 * 1024
        const val MEDIA_LIMIT = 32 * 1024 * 1024
        const val MAX_HEADERS = 128
        /** Requests of one document at once (as a browser's 6 connections per host). */
        const val MAX_IN_FLIGHT = 6
        const val MAX_REDIRECTS = 10
        const val TIMEOUT_SECONDS = 30L

        private val METHODS = setOf("GET", "HEAD", "POST", "PUT", "PATCH", "DELETE")
        private val SIMPLE_METHODS = setOf("GET", "HEAD", "POST")
        private val BODY_METHODS = setOf("POST", "PUT", "PATCH")
        private val REDIRECT_CODES = setOf(301, 302, 303, 307, 308)
        private val CREDENTIAL_HEADERS = setOf("authorization", "cookie", "cookie2", "proxy-authorization")
        private val FORBIDDEN_HEADERS = setOf(
            "accept-charset", "accept-encoding", "access-control-request-headers",
            "access-control-request-method", "connection", "content-length", "date", "dnt",
            "expect", "host", "keep-alive", "origin", "permissions-policy", "referer", "te",
            "trailer", "transfer-encoding", "upgrade", "via", "user-agent",
        )
        private val SAFELISTED_RESPONSE_HEADERS = setOf(
            "cache-control", "content-language", "content-length", "content-type",
            "expires", "last-modified", "pragma",
        )
        private val FORBIDDEN_RESPONSE_HEADERS = setOf("set-cookie", "set-cookie2")
        private val SIMPLE_CONTENT_TYPES = setOf(
            "application/x-www-form-urlencoded", "multipart/form-data", "text/plain",
        )
        private val TOKEN = Regex("^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
        private val NUMERIC_HOST = Regex("^[0-9.]+$")
        private val CANONICAL_IPV4 = Regex("^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}$")
        private val REQUEST_ID = Regex("^[A-Za-z0-9._:-]{1,128}$")
        private val BODY_HEADERS = setOf("content-type", "content-encoding", "content-language", "content-location")

        /** Absolute `http`/`https` URLs only; a message document has no base URL. */
        fun absoluteUrl(value: String): HttpUrl {
            require(value.length <= 8192) { "The URL is too long" }
            val scheme = value.substringBefore(':', "").lowercase()
            if (scheme != "http" && scheme != "https") {
                throw ScriptFailure("RESOURCE", "Only absolute http and https URLs can be loaded.")
            }
            return value.toHttpUrlOrNull() ?: throw ScriptFailure("RESOURCE", "The URL is not valid.")
        }

        /**
         * Whether [address] is on the public internet. Loopback, private (including the
         * 100.64.0.0/10 range Tailscale uses), link-local, multicast and unspecified addresses
         * are refused. An IPv6 address that carries an IPv4 one is checked as that address;
         * Teredo (2001::/32) is refused.
         */
        fun isPublicAddress(address: InetAddress): Boolean {
            if (address.isAnyLocalAddress || address.isLoopbackAddress || address.isLinkLocalAddress ||
                address.isSiteLocalAddress || address.isMulticastAddress
            ) return false
            val bytes = address.address
            return when (address) {
                is Inet4Address -> {
                    val a = bytes[0].toInt() and 0xff
                    val b = bytes[1].toInt() and 0xff
                    !(a == 0 || a == 10 || a == 127 || a >= 224 ||
                        a == 100 && b in 64..127 || a == 169 && b == 254 ||
                        a == 172 && b in 16..31 || a == 192 && b == 168 ||
                        a == 192 && b == 0 && (bytes[2].toInt() and 0xff) == 0 || a == 198 && b in 18..19)
                }
                is Inet6Address -> {
                    fun u(i: Int) = bytes[i].toInt() and 0xff
                    fun embedded(from: Int) = isPublicAddress(InetAddress.getByAddress(bytes.copyOfRange(from, from + 4)))
                    val zeros = (0 until 10).all { u(it) == 0 }
                    when {
                        // ::ffff:a.b.c.d (mapped) and ::a.b.c.d (compatible) are checked as IPv4.
                        zeros && u(10) == 0xff && u(11) == 0xff -> embedded(12)
                        zeros && u(10) == 0 && u(11) == 0 -> embedded(12)
                        // NAT64 64:ff9b::/96 carries the IPv4 target in its last 32 bits.
                        u(0) == 0x00 && u(1) == 0x64 && u(2) == 0xff && u(3) == 0x9b &&
                            (4 until 12).all { u(it) == 0 } -> embedded(12)
                        // The local-use NAT64 prefix 64:ff9b:1::/48 (RFC 8215): the network
                        // picks where the IPv4 address goes, so only the /96 form is read, and
                        // every other form is refused.
                        u(0) == 0x00 && u(1) == 0x64 && u(2) == 0xff && u(3) == 0x9b && u(4) == 0x00 && u(5) == 0x01 ->
                            (6 until 12).all { u(it) == 0 } && embedded(12)
                        // Teredo 2001::/32 tunnels to an IPv4 address that the policy cannot see.
                        u(0) == 0x20 && u(1) == 0x01 && u(2) == 0x00 && u(3) == 0x00 -> false
                        // 6to4 2002::/16 carries it in bits 16–47.
                        u(0) == 0x20 && u(1) == 0x02 -> embedded(2)
                        // fc00::/7 unique local.
                        else -> u(0) and 0xfe != 0xfc
                    }
                }
                else -> false
            }
        }
    }
}
