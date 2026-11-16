package dev.pirc.pirc_mobile

import dev.pirc.android.core.Pairing
import java.io.IOException
import java.io.File
import kotlinx.serialization.json.*
import java.net.InetAddress
import java.util.concurrent.TimeUnit
import mockwebserver3.MockResponse
import mockwebserver3.MockResponseBody
import mockwebserver3.Dispatcher
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import mockwebserver3.SocketEffect
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.Dns
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okio.BufferedSink
import org.junit.Assert.*
import org.junit.Test

class NativeDocumentTransportTest {
    @Test fun mediaResourceUsesGetAcceptsMediaAndKeepsPairingAuthorization() {
        MockWebServer().use { server ->
            server.enqueue(
                MockResponse.Builder()
                    .addHeader("Content-Type", "audio/ogg")
                    .body("media")
                    .build(),
            )
            server.start()

            val response = NativeDocumentTransport(pairing(server), initiator = appInitiated(pairing(server))).load(
                server.url("/media.ogg").toString(),
                "GET",
                null,
                null,
                resourceType = NativeDocumentTransport.ResourceType.MEDIA,
                referrerUrl = "https://source.example.test/private?token=1",
                referrerPolicy = "unsafe-url",
            )
            val request = server.takeRequest()

            assertEquals("GET", request.method)
            assertEquals("audio/*,video/*,*/*;q=0.1", request.headers["Accept"])
            assertEquals("Bearer device-token", request.headers["Authorization"])
            assertNull(request.headers["Referer"])
            assertNull(request.headers["Origin"])
            assertEquals("", response["requestReferrer"])
            assertEquals("no-referrer", response["requestReferrerPolicy"])
            assertNull(response["requestOrigin"])
            assertEquals("null", response["requestOriginSource"])
            assertArrayEquals("media".toByteArray(), response["bytes"] as ByteArray)
            assertEquals("audio/ogg", response["mimeType"])
        }
    }

    @Test fun mediaResourceFromContentCarriesNoPairingAuthorizationOrReferrer() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse.Builder().addHeader("Content-Type", "audio/ogg").body("media").build())
            server.start()
            val page = server.url("/?session=s").toString()
            NativeDocumentTransport(pairing(server)).load(
                server.url("/api/sessions/s/browser/recording").toString(), "GET", null, null,
                resourceType = NativeDocumentTransport.ResourceType.MEDIA,
                referrerUrl = page, referrerPolicy = "unsafe-url", initiatorUrl = page, topLevelUrl = page,
            )
            val request = server.takeRequest()
            assertNull(request.headers["Authorization"])
            assertNull(request.headers["Referer"])
            assertNull(request.headers["Cookie"])
        }
    }

    @Test fun postOriginIsSeparateFromRefererAndLimitedToDocumentPosts() {
        MockWebServer().use { server ->
            server.start()
            val sourceOrigin = "https://creator.example:443/private/page?query=1#fragment"
            val otherSource = "http://other.example/path?secret=1"
            repeat(7) { server.enqueue(MockResponse.Builder().body("ok").build()) }
            val transport = NativeDocumentTransport(null)

            val separated = transport.load(
                server.url("/document").toString(),
                "POST",
                "fixed=body",
                null,
                referrerUrl = sourceOrigin,
                referrerPolicy = "no-referrer",
                originUrl = sourceOrigin,
            )
            val separatedRequest = server.takeRequest()
            assertEquals("POST", separatedRequest.method)
            assertEquals("fixed=body", separatedRequest.body?.utf8())
            assertNull(separatedRequest.headers["Referer"])
            assertEquals("null", separatedRequest.headers["Origin"])
            assertEquals("null", separated["requestOrigin"])
            assertEquals("https://creator.example", separated["requestOriginSource"])

            val unsafeUrl = transport.load(
                server.url("/unsafe-url").toString(),
                "POST",
                "synthetic=unsafe-url",
                null,
                referrerUrl = sourceOrigin,
                referrerPolicy = "unsafe-url",
                originUrl = sourceOrigin,
            )
            assertEquals("https://creator.example", server.takeRequest().headers["Origin"])
            assertEquals("https://creator.example", unsafeUrl["requestOrigin"])
            assertEquals("https://creator.example", unsafeUrl["requestOriginSource"])

            val opaque = transport.load(
                server.url("/opaque").toString(),
                "POST",
                "synthetic=1",
                null,
                referrerUrl = "https://visible.example/path",
                referrerPolicy = "unsafe-url",
                originUrl = "null",
            )
            assertEquals("null", server.takeRequest().headers["Origin"])
            assertEquals("null", opaque["requestOrigin"])
            assertEquals("null", opaque["requestOriginSource"])

            val inferred = transport.load(
                server.url("/inferred").toString(),
                "POST",
                "synthetic=2",
                null,
                referrerUrl = server.url("/private/source?query=1#fragment").toString(),
                referrerPolicy = "unsafe-url",
            )
            val inferredOrigin = server.url("/").toString().removeSuffix("/")
            assertEquals(inferredOrigin, server.takeRequest().headers["Origin"])
            assertEquals(inferredOrigin, inferred["requestOriginSource"])

            val sameOrigin = transport.load(
                server.url("/same").toString(),
                "POST",
                "synthetic=3",
                null,
                referrerUrl = server.url("/private/source").toString(),
                referrerPolicy = "same-origin",
            )
            assertEquals(inferredOrigin, server.takeRequest().headers["Origin"])
            assertEquals(inferredOrigin, sameOrigin["requestOrigin"])

            val crossOrigin = transport.load(
                server.url("/cross").toString(),
                "POST",
                "synthetic=4",
                null,
                referrerUrl = otherSource,
                referrerPolicy = "same-origin",
            )
            assertEquals("null", server.takeRequest().headers["Origin"])
            assertEquals("null", crossOrigin["requestOrigin"])
            assertEquals("http://other.example", crossOrigin["requestOriginSource"])

            val get = transport.load(
                server.url("/get").toString(),
                "GET",
                null,
                null,
                referrerUrl = sourceOrigin,
                originUrl = sourceOrigin,
            )
            assertNull(server.takeRequest().headers["Origin"])
            assertNull(get["requestOrigin"])
            assertEquals("https://creator.example", get["requestOriginSource"])
            assertEquals(7, server.requestCount)
        }
    }

    @Test fun postOriginAppliesSchemeDowngradePoliciesAndBecomesOpaqueAfterTaintedRedirects() {
        MockWebServer().use { gateway ->
            MockWebServer().use { crossOrigin ->
                gateway.start()
                crossOrigin.start()
                val gatewayOrigin = gateway.url("/").toString().removeSuffix("/")

                for (policy in listOf(
                    "no-referrer-when-downgrade",
                    "strict-origin",
                    "strict-origin-when-cross-origin",
                )) {
                    gateway.enqueue(MockResponse.Builder().body("ok").build())
                    NativeDocumentTransport(null).load(
                        gateway.url("/strict-downgrade").toString(),
                        "POST",
                        "synthetic=1",
                        null,
                        referrerUrl = "https://secure.example/private",
                        referrerPolicy = policy,
                    )
                    assertEquals("null", gateway.takeRequest().headers["Origin"])
                }

                gateway.enqueue(
                    MockResponse.Builder()
                        .code(307)
                        .addHeader("Location", crossOrigin.url("/policy").toString())
                        .addHeader("Referrer-Policy", "no-referrer")
                        .build(),
                )
                crossOrigin.enqueue(
                    MockResponse.Builder()
                        .code(307)
                        .addHeader("Location", crossOrigin.url("/same-origin-redirect").toString())
                        .addHeader("Referrer-Policy", "unsafe-url")
                        .build(),
                )
                crossOrigin.enqueue(
                    MockResponse.Builder()
                        .code(307)
                        .addHeader("Location", gateway.url("/tainted-final").toString())
                        .build(),
                )
                gateway.enqueue(MockResponse.Builder().body("done").build())
                val response = NativeDocumentTransport(pairing(gateway), initiator = appInitiated(pairing(gateway))).load(
                    gateway.url("/start").toString(),
                    "POST",
                    "synthetic=2",
                    null,
                    originUrl = gatewayOrigin,
                    referrerPolicy = "unsafe-url",
                )

                val first = gateway.takeRequest()
                val second = crossOrigin.takeRequest()
                val third = crossOrigin.takeRequest()
                val final = gateway.takeRequest()
                assertEquals(gatewayOrigin, first.headers["Origin"])
                assertEquals("Bearer device-token", first.headers["Authorization"])
                assertEquals("null", second.headers["Origin"])
                assertNull(second.headers["Authorization"])
                assertEquals(gatewayOrigin, third.headers["Origin"])
                assertNull(third.headers["Authorization"])
                assertEquals("null", final.headers["Origin"])
                // Once the chain has left the paired origin the credential is not restored.
                assertNull(final.headers["Authorization"])
                assertEquals("null", response["requestOrigin"])
                assertEquals(gatewayOrigin, response["requestOriginSource"])
                assertEquals("unsafe-url", response["requestReferrerPolicy"])
            }
        }
    }

    @Test fun documentRefererPoliciesSanitizeAndExposeTheWireValue() {
        MockWebServer().use { server ->
            server.start()
            val origin = "http://source.example.test/"
            val full = "http://source.example.test/private/page?query=1"
            val source = "http://user:secret@source.example.test/private/page?query=1#fragment"
            val policyCases = listOf(
                null to origin,
                "no-referrer" to "",
                "no-referrer-when-downgrade" to full,
                "origin" to origin,
                "origin-when-cross-origin" to origin,
                "same-origin" to "",
                "strict-origin" to origin,
                "strict-origin-when-cross-origin" to origin,
                "unsafe-url" to full,
            )

            policyCases.forEach { (policy, expected) ->
                server.enqueue(MockResponse.Builder().body("ok").build())
                val response = NativeDocumentTransport(null).load(
                    server.url("/document").toString(),
                    "GET",
                    null,
                    null,
                    referrerUrl = source,
                    referrerPolicy = policy,
                )
                val request = server.takeRequest()

                assertEquals(expected, request.headers["Referer"].orEmpty())
                assertEquals(expected, response["requestReferrer"])
                assertEquals(
                    policy ?: "strict-origin-when-cross-origin",
                    response["requestReferrerPolicy"],
                )
            }

            val sameOriginSource = server.url("/private/page?query=1#fragment").toString()
            val sameOriginFull = sameOriginSource.substringBefore('#')
            val sameOriginOrigin = server.url("/").toString()
            val sameOriginCases = listOf(
                null to sameOriginFull,
                "no-referrer" to "",
                "no-referrer-when-downgrade" to sameOriginFull,
                "origin" to sameOriginOrigin,
                "origin-when-cross-origin" to sameOriginFull,
                "same-origin" to sameOriginFull,
                "strict-origin" to sameOriginOrigin,
                "strict-origin-when-cross-origin" to sameOriginFull,
                "unsafe-url" to sameOriginFull,
            )
            sameOriginCases.forEach { (policy, expected) ->
                server.enqueue(MockResponse.Builder().body("ok").build())
                val response = NativeDocumentTransport(null).load(
                    server.url("/document").toString(),
                    "GET",
                    null,
                    null,
                    referrerUrl = sameOriginSource,
                    referrerPolicy = policy,
                )
                val request = server.takeRequest()

                assertEquals(expected, request.headers["Referer"].orEmpty())
                assertEquals(expected, response["requestReferrer"])
                assertEquals(
                    policy ?: "strict-origin-when-cross-origin",
                    response["requestReferrerPolicy"],
                )
            }
            assertEquals(policyCases.size + sameOriginCases.size, server.requestCount)
        }
    }

    @Test fun malformedOrNonHttpSourcesAndOverlongSourcesAreHandledSafely() {
        MockWebServer().use { server ->
            server.start()
            listOf(
                "blob:https://source.example.test/document",
                "data:text/plain,private",
                "https:opaque",
                "not a URL",
            ).forEach { source ->
                server.enqueue(MockResponse.Builder().body("ok").build())
                val response = NativeDocumentTransport(null).load(
                    server.url("/document").toString(),
                    "GET",
                    null,
                    null,
                    referrerUrl = source,
                    referrerPolicy = "unsafe-url",
                )
                val request = server.takeRequest()
                assertNull(request.headers["Referer"])
                assertEquals("", response["requestReferrer"])
            }

            val origin = "http://source.example.test/"
            val exactLength = origin + "x".repeat(4096 - origin.length)
            val overLength = exactLength + "x"
            listOf(exactLength to exactLength, overLength to origin).forEach { (source, expected) ->
                server.enqueue(MockResponse.Builder().body("ok").build())
                val response = NativeDocumentTransport(null).load(
                    server.url("/document").toString(),
                    "GET",
                    null,
                    null,
                    referrerUrl = source,
                    referrerPolicy = "unsafe-url",
                )
                val request = server.takeRequest()
                assertEquals(expected, request.headers["Referer"])
                assertEquals(expected, response["requestReferrer"])
            }
        }
    }

    @Test fun redirectCarriesOnlyDisclosedRefererAndUpdatesPolicyWithoutAuthLeakage() {
        MockWebServer().use { gateway ->
            MockWebServer().use { external ->
                gateway.start()
                external.start()
                gateway.enqueue(
                    MockResponse.Builder()
                        .code(302)
                        .addHeader("Location", external.url("/landing").toString())
                        .addHeader("Referrer-Policy", "same-origin, unknown")
                        .addHeader("Referrer-Policy", "UNSAFE-URL")
                        .build(),
                )
                external.enqueue(
                    MockResponse.Builder()
                        .addHeader("Referrer-Policy", "no-referrer")
                        .body("landed")
                        .build(),
                )
                val response = NativeDocumentTransport(pairing(gateway), initiator = appInitiated(pairing(gateway))).load(
                    gateway.url("/start").toString(),
                    "GET",
                    null,
                    null,
                    referrerUrl = "http://user:secret@source.example.test/private/path?query=1#fragment",
                    referrerPolicy = "strict-origin-when-cross-origin",
                )
                val first = gateway.takeRequest()
                val final = external.takeRequest()

                assertEquals("http://source.example.test/", first.headers["Referer"])
                assertEquals("Bearer device-token", first.headers["Authorization"])
                assertEquals("http://source.example.test/", final.headers["Referer"])
                assertNull(final.headers["Authorization"])
                assertEquals("http://source.example.test/", response["requestReferrer"])
                assertEquals("unsafe-url", response["requestReferrerPolicy"])
            }
        }
    }

    @Test fun strictPolicyTreatsTlsAndLoopbackAsTrustworthyForDowngrades() {
        MockWebServer().use { server ->
            server.start()
            val target = server.url("/document")
                .newBuilder()
                .host("destination.example.test")
                .build()
            val client = OkHttpClient.Builder()
                .dns(
                    Dns { _ ->
                        listOf(InetAddress.getByName("127.0.0.1"))
                    },
                )
                .build()

            listOf(
                "https://secure.example.test/private/path?secret=1#fragment",
                "http://localhost/private/path?secret=1#fragment",
                "http://127.0.0.1/private/path?secret=1#fragment",
                "http://[::1]/private/path?secret=1#fragment",
            ).forEach { source ->
                server.enqueue(MockResponse.Builder().body("ok").build())
                val response = NativeDocumentTransport(null, client).load(
                    target.toString(),
                    "GET",
                    null,
                    null,
                    referrerUrl = source,
                    referrerPolicy = "strict-origin-when-cross-origin",
                )
                val request = server.takeRequest()
                assertNull(request.headers["Referer"])
                assertEquals("", response["requestReferrer"])
                assertEquals("strict-origin-when-cross-origin", response["requestReferrerPolicy"])
            }
            assertEquals(4, server.requestCount)
        }
    }

    @Test fun actualWireRequestsReplayThirtyIndependentChromium153PolicyCases() {
        val fixture = listOf(
            File("../../tool/parity/fixtures/document-referrer-chromium153.json"),
            File("../tool/parity/fixtures/document-referrer-chromium153.json"),
        ).firstOrNull { it.isFile } ?: error("Chromium 153 referrer fixture is unavailable")
        val oracle = Json.parseToJsonElement(fixture.readText()).jsonObject
        val cases = oracle.getValue("cases").jsonArray
        val policies = oracle.getValue("policyNames").jsonArray.map { it.jsonPrimitive.content }.toSet()
        assertEquals(30, cases.size)
        MockWebServer().use { same ->
            MockWebServer().use { cross ->
                same.start()
                cross.start()
                fun replaceOrigins(text: String) = text
                    .replace(":43178", ":${same.port}")
                    .replace(":43179", ":${cross.port}")
                for (raw in cases) {
                    val spec = raw.jsonObject
                    fun text(key: String) = (spec[key] as? JsonPrimitive)?.contentOrNull.orEmpty()
                    fun recognized(value: String): String? = value.trim().lowercase()
                        .takeIf { it in policies }
                    var initialPolicy = "strict-origin-when-cross-origin"
                    for (part in text("headerPolicy").split(',')) {
                        recognized(part)?.let { initialPolicy = it }
                    }
                    recognized(text("metaPolicy"))?.let { initialPolicy = it }
                    recognized(text("elementPolicy"))?.let { initialPolicy = it }
                    if (text("rel").lowercase().split(Regex("\\s+")).contains("noreferrer")) {
                        initialPolicy = "no-referrer"
                    }
                    val hops = spec.getValue("requestHops").jsonArray
                    for ((index, rawHop) in hops.withIndex()) {
                        val hop = rawHop.jsonObject
                        val server = if (hop.getValue("server").jsonPrimitive.content == "same") same else cross
                        val reply = MockResponse.Builder().body("local policy replay")
                        if (index + 1 < hops.size) {
                            reply.code(302).addHeader("Location", replaceOrigins(hops[index + 1].jsonObject.getValue("url").jsonPrimitive.content))
                        }
                        (hop["responseReferrerPolicy"] as? JsonPrimitive)?.contentOrNull?.let {
                            reply.addHeader("Referrer-Policy", it)
                        }
                        server.enqueue(reply.build())
                    }
                    val response = NativeDocumentTransport(pairing(same)).load(
                        replaceOrigins(text("targetUrl")), "GET", null, null,
                        referrerUrl = replaceOrigins(text("sourceUrl")),
                        referrerPolicy = initialPolicy,
                    )
                    for (rawHop in hops) {
                        val hop = rawHop.jsonObject
                        val server = if (hop.getValue("server").jsonPrimitive.content == "same") same else cross
                        val request = server.takeRequest()
                        val label = text("caseId") + " hop " + hop.getValue("hop").jsonPrimitive.content
                        assertEquals(label, hop.getValue("method").jsonPrimitive.content, request.method)
                        assertEquals(label, replaceOrigins(hop.getValue("referer").jsonPrimitive.content), request.headers["Referer"].orEmpty())
                        assertEquals(label, hop.getValue("path").jsonPrimitive.content, request.url.encodedPath)
                        if (server === cross) assertNull(label, request.headers["Authorization"])
                    }
                    val last = hops.last().jsonObject
                    assertEquals(text("caseId"), replaceOrigins(last.getValue("referer").jsonPrimitive.content), response["requestReferrer"])
                }
            }
        }
    }

    @Test fun noReferrerCannotBeRecoveredByALaterUnsafeRedirectPolicy() {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse.Builder().code(302)
                .addHeader("Location", server.url("/final").toString())
                .addHeader("Referrer-Policy", "unsafe-url").build())
            server.enqueue(MockResponse.Builder().body("final").build())
            val response = NativeDocumentTransport(null).load(server.url("/initial").toString(),
                "POST", "fixed=body", "application/x-www-form-urlencoded",
                referrerUrl = "https://source.example/private?synthetic=1", referrerPolicy = "no-referrer")
            val first = server.takeRequest()
            val final = server.takeRequest()
            assertEquals("POST", first.method)
            assertEquals("fixed=body", first.body?.utf8())
            assertEquals("GET", final.method)
            assertNull(first.headers["Referer"])
            assertNull(final.headers["Referer"])
            assertEquals("null", first.headers["Origin"])
            assertNull(final.headers["Origin"])
            assertEquals("", response["requestReferrer"])
            assertEquals("unsafe-url", response["requestReferrerPolicy"])
            assertNull(response["requestOrigin"])
            assertEquals("https://source.example", response["requestOriginSource"])
        }
    }

    @Test fun mediaResourceRejectsPostAndStillUsesConfiguredByteLimit() {
        val transport = NativeDocumentTransport(null, OkHttpClient(), limit = 3)
        try {
            transport.load(
                "https://example.test/media",
                "POST",
                null,
                null,
                resourceType = NativeDocumentTransport.ResourceType.MEDIA,
            )
            fail("Media resources must be GET-only")
        } catch (_: IllegalArgumentException) { }

        MockWebServer().use { server ->
            server.enqueue(
                MockResponse.Builder().body(
                    object : MockResponseBody {
                        override val contentLength: Long = 4
                        override fun writeTo(sink: BufferedSink) {
                            sink.write(byteArrayOf(1, 2, 3, 4))
                        }
                    },
                ).build(),
            )
            server.start()
            try {
                NativeDocumentTransport(null, OkHttpClient(), limit = 3).load(
                    server.url("/large-media").toString(),
                    "GET",
                    null,
                    null,
                    resourceType = NativeDocumentTransport.ResourceType.MEDIA,
                )
                fail("Media resources must keep the configured response cap")
            } catch (_: IllegalStateException) { }
        }
    }

    @Test fun binaryPostPreservesNonUtf8BytesAnd307Replay() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse.Builder().code(307).addHeader("Location", "/final").build())
            server.enqueue(MockResponse.Builder().body("ok").build())
            server.start()
            val payload = byteArrayOf(0, 127, -128, -1, 13, 10)
            val type = "multipart/form-data; boundary=test-boundary"
            NativeDocumentTransport(pairing(server)).load(
                server.url("/upload").toString(), "POST", null, type,
                bodyBytes = payload,
            )
            repeat(2) {
                val request = server.takeRequest()
                assertEquals("POST", request.method)
                assertEquals(type, request.headers["Content-Type"])
                assertArrayEquals(payload, request.body!!.toByteArray())
            }
        }
    }

    @Test fun binaryBodiesCannotBeUsedWithGetOrMixedText() {
        val transport = NativeDocumentTransport(null)
        for ((method, text) in listOf("GET" to null, "POST" to "text")) {
            try {
                transport.load("https://example.test/", method, text, null, bodyBytes = byteArrayOf(1))
                fail("Invalid body shape must be rejected before sending")
            } catch (_: IllegalArgumentException) { }
        }
    }

    private val formContentType = "application/x-www-form-urlencoded; charset=UTF-8"

    @Test fun nativeCookiesFollowRedirectsProcess304AndNeverExposeSetCookie() {
        MockWebServer().use { server ->
            server.enqueue(
                MockResponse.Builder()
                    .code(302)
                    .addHeader("Location", "/redirected")
                    .addHeader("Set-Cookie", "sid=redirect; Path=/; SameSite=Lax")
                    .build(),
            )
            server.enqueue(MockResponse.Builder().body("redirected").build())
            server.enqueue(
                MockResponse.Builder()
                    .code(304)
                    .addHeader("Set-Cookie", "revalidated=yes; Path=/; SameSite=Lax")
                    .build(),
            )
            server.enqueue(MockResponse.Builder().body("after").build())
            server.start()

            val cookies = NativeDocumentCookies()
            var jarLoads = 0
            val ambientJar = object : CookieJar {
                override fun loadForRequest(url: HttpUrl): List<Cookie> {
                    jarLoads++
                    return listOf(checkNotNull(Cookie.parse(url, "ambient=must-not-leak; Path=/")))
                }

                override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) = Unit
            }
            val transport = NativeDocumentTransport(
                null,
                OkHttpClient.Builder().cookieJar(ambientJar).build(),
                cookies = cookies,
            )
            val pageUrl = server.url("/page").toString()
            val response = transport.load(
                server.url("/start").toString(),
                "GET",
                null,
                null,
                initiatorUrl = pageUrl,
                topLevelUrl = pageUrl,
            )
            val firstHop = server.takeRequest()
            val redirected = server.takeRequest()
            assertNull(firstHop.headers["Cookie"])
            assertEquals("sid=redirect", redirected.headers["Cookie"])
            assertEquals(
                opaqueCookieRequestKey("sid=redirect"),
                response["nativeCookieRequestKey"],
            )

            val notModifiedResponse = transport.load(
                server.url("/revalidate").toString(),
                "GET",
                null,
                null,
                cacheMode = NativeDocumentTransport.CacheMode.REVALIDATE,
                ifNoneMatch = "\"cached\"",
                initiatorUrl = pageUrl,
                topLevelUrl = pageUrl,
            )
            val notModified = server.takeRequest()
            assertEquals("\"cached\"", notModified.headers["If-None-Match"])
            assertEquals("sid=redirect", notModified.headers["Cookie"])
            assertEquals(304, notModifiedResponse["status"])
            assertEquals(
                opaqueCookieRequestKey("sid=redirect"),
                notModifiedResponse["nativeCookieRequestKey"],
            )
            assertEquals(true, notModifiedResponse["nativeSetCookieProcessed"])
            assertEquals(200, response["status"])
            assertEquals(true, response["nativeSetCookieProcessed"])
            val headers = notModifiedResponse["headersRelevant"] as Map<*, *>
            assertFalse(headers.keys.any { it.toString().equals("Set-Cookie", ignoreCase = true) })

            transport.load(server.url("/after").toString(), "GET", null, null, initiatorUrl = pageUrl)
            assertEquals("sid=redirect; revalidated=yes", server.takeRequest().headers["Cookie"])
            assertEquals(0, jarLoads)
        }
    }

    // ---- credential boundary: who started the request decides what identity it carries ----

    private val pairedIdentityHeaders = listOf("Authorization", "X-Pirc-Management", "X-Pirc-Request", "Cookie")

    private fun assertNoPairedIdentity(request: RecordedRequest) {
        pairedIdentityHeaders.forEach { assertNull(it, request.headers[it]) }
    }

    private fun cookieContextFor(page: HttpUrl) =
        CookieRequestContext(initiatorUrl = page, topLevelUrl = page, topLevelNavigation = true)

    @Test fun contentInitiatedRequestsToThePairedOriginCarryNoPairedIdentity() {
        MockWebServer().use { gateway ->
            repeat(5) {
                gateway.enqueue(MockResponse.Builder().addHeader("Set-Cookie", "gw=1; Path=/").body("{}").build())
            }
            gateway.start()
            val page = gateway.url("/?session=s1")
            val cookies = NativeDocumentCookies()
            cookies.receive(gateway.url("/"), listOf("seed=1; Path=/"), cookieContextFor(page))
            // No initiator is declared: unspecified means page content.
            val transport = NativeDocumentTransport(pairing(gateway), cookies = cookies)
            val common = mapOf("initiatorUrl" to page.toString())

            transport.load(gateway.url("/api/sessions").toString(), "GET", null, null,
                initiatorUrl = common["initiatorUrl"], topLevelUrl = common["initiatorUrl"])
            for ((type, body) in listOf(
                "text/plain" to "a=1",
                "application/x-www-form-urlencoded" to "a=1",
                "application/x-www-form-urlencoded; charset=UTF-8" to "",
            )) {
                transport.load(gateway.url("/api/sessions/s1/commands").toString(), "POST", body, type,
                    originUrl = page.toString(), referrerUrl = page.toString(),
                    initiatorUrl = page.toString(), topLevelUrl = page.toString())
            }
            transport.load(gateway.url("/api/workspaces/w/files?filename=x").toString(), "POST", null,
                "multipart/form-data; boundary=b", bodyBytes = "--b--\r\n".toByteArray(),
                originUrl = page.toString(), initiatorUrl = page.toString(), topLevelUrl = page.toString())

            val recorded = List(5) { gateway.takeRequest() }
            recorded.forEach(::assertNoPairedIdentity)
            // Content is not first-party: its POSTs name an opaque origin, even to the paired origin.
            recorded.filter { it.method == "POST" }.also { assertEquals(4, it.size) }
                .forEach { assertEquals("null", it.headers["Origin"]) }
            assertNull(recorded.first().headers["Origin"])
            // The Gateway's own Set-Cookie on a content request is not stored for later reuse.
            assertEquals("seed=1", cookies.requestHeader(gateway.url("/"), cookieContextFor(page)))
        }
    }

    @Test fun appInitiatedRequestsToThePairedOriginStillCarryTheCredentialAndCookieScope() {
        MockWebServer().use { gateway ->
            repeat(2) { gateway.enqueue(MockResponse.Builder().body("{}").build()) }
            gateway.start()
            val page = gateway.url("/")
            val cookies = NativeDocumentCookies()
            cookies.receive(page, listOf("seed=1; Path=/"), cookieContextFor(page))
            val p = pairing(gateway)
            val transport = NativeDocumentTransport(p, cookies = cookies, initiator = appInitiated(p))
            transport.load(gateway.url("/api/sessions").toString(), "GET", null, null,
                initiatorUrl = page.toString(), topLevelUrl = page.toString())
            transport.load(gateway.url("/api/sessions").toString(), "POST", "a=1", "text/plain",
                initiatorUrl = page.toString(), topLevelUrl = page.toString())
            repeat(2) {
                val request = gateway.takeRequest()
                assertEquals("Bearer device-token", request.headers["Authorization"])
                assertEquals("seed=1", request.headers["Cookie"])
                assertNull(request.headers["X-Pirc-Management"])
            }
        }
    }

    @Test fun externalRedirectBackToThePairedOriginNeverRestoresTheCredential() {
        MockWebServer().use { gateway -> MockWebServer().use { external ->
            gateway.start(); external.start()
            val back = gateway.url("/api/sessions").toString()
            // Content-initiated chain: external hop, then back to the Gateway.
            external.enqueue(MockResponse.Builder().code(302).addHeader("Location", back).build())
            gateway.enqueue(MockResponse.Builder().body("{}").build())
            NativeDocumentTransport(pairing(gateway)).load(external.url("/start").toString(), "GET", null, null)
            assertNoPairedIdentity(external.takeRequest())
            assertNoPairedIdentity(gateway.takeRequest())

            // App-initiated chain that leaves the origin and returns: not restored either (GET and POST).
            for (method in listOf("GET", "POST")) {
                gateway.enqueue(MockResponse.Builder().code(307).addHeader("Location", external.url("/hop")).build())
                external.enqueue(MockResponse.Builder().code(307).addHeader("Location", back).build())
                gateway.enqueue(MockResponse.Builder().body("{}").build())
                val p = pairing(gateway)
                NativeDocumentTransport(p, initiator = appInitiated(p)).load(
                    gateway.url("/api/start").toString(), method, if (method == "POST") "a=1" else null, null)
                assertEquals("Bearer device-token", gateway.takeRequest().headers["Authorization"])
                assertNoPairedIdentity(external.takeRequest())
                assertNoPairedIdentity(gateway.takeRequest())
            }
        } }
    }

    @Test fun anUntrustedChainAndItsSameOriginRedirectsNeverCarryTheCredential() {
        MockWebServer().use { gateway ->
            gateway.enqueue(MockResponse.Builder().code(302).addHeader("Location", "/api/next").build())
            gateway.enqueue(MockResponse.Builder().body("{}").build())
            gateway.start()
            NativeDocumentTransport(pairing(gateway)).load(gateway.url("/api/start").toString(), "GET", null, null)
            repeat(2) { assertNoPairedIdentity(gateway.takeRequest()) }
        }
    }

    @Test fun aFormToAnExternalOriginIsDeliveredIntactWithoutPairedIdentity() {
        MockWebServer().use { gateway -> MockWebServer().use { external ->
            gateway.start(); external.start()
            val page = gateway.url("/?session=SESSION-ID-1")
            val transport = NativeDocumentTransport(pairing(gateway), cookies = NativeDocumentCookies())
            val cases = listOf(
                Triple("application/x-www-form-urlencoded", "name=%E4%BD%A0&x=1".toByteArray(), false),
                Triple("text/plain", "name=你\r\nx=1\r\n".toByteArray(), false),
                Triple("multipart/form-data; boundary=zz", "--zz\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n--zz--\r\n".toByteArray(), true),
            )
            for ((type, payload, binary) in cases) {
                external.enqueue(MockResponse.Builder().body("ok").build())
                transport.load(external.url("/submit").toString(), "POST",
                    if (binary) null else String(payload, Charsets.UTF_8), type,
                    bodyBytes = if (binary) payload else null,
                    originUrl = page.toString(), referrerUrl = page.toString(),
                    initiatorUrl = page.toString(), topLevelUrl = page.toString())
                val request = external.takeRequest()
                assertEquals(type, request.headers["Content-Type"])
                assertArrayEquals(payload, request.body!!.toByteArray())
                assertNoPairedIdentity(request)
                assertEquals("null", request.headers["Origin"])
                assertNull(request.headers["Referer"])
                request.headers.forEach { (_, value) ->
                    assertFalse(value.contains("SESSION-ID-1"))
                    assertFalse(value.contains(gateway.hostName + ":" + gateway.port))
                }
            }
        } }
    }

    @Test fun contentInitiatedRefererNeverNamesTheInternalDocumentOutsideThePairedOrigin() {
        MockWebServer().use { gateway -> MockWebServer().use { external -> MockWebServer().use { other ->
            gateway.start(); external.start(); other.start()
            val internal = gateway.url("/?session=SESSION-ID-2").toString()
            val gatewayOrigin = gateway.url("/").toString().removeSuffix("/")
            val policies = listOf(
                null, "no-referrer", "no-referrer-when-downgrade", "origin", "origin-when-cross-origin",
                "same-origin", "strict-origin", "strict-origin-when-cross-origin", "unsafe-url",
                "UNSAFE-URL", "bogus, unsafe-url",
            )
            fun assertNothingLeaks(request: RecordedRequest) {
                request.headers.forEach { (name, value) ->
                    assertFalse("$name: $value", value.contains("SESSION-ID-2"))
                    assertFalse("$name: $value", value.contains(gatewayOrigin))
                }
                assertNull(request.headers["Referer"])
            }
            for (policy in policies) for (method in listOf("GET", "POST")) {
                // Direct request, then one that redirects (with a loosening response policy) onward.
                external.enqueue(MockResponse.Builder().body("ok").build())
                NativeDocumentTransport(pairing(gateway)).load(
                    external.url("/direct").toString(), method, if (method == "POST") "a=1" else null, null,
                    referrerUrl = internal, referrerPolicy = policy, originUrl = internal,
                )
                assertNothingLeaks(external.takeRequest())

                external.enqueue(MockResponse.Builder().code(307).addHeader("Location", other.url("/second"))
                    .addHeader("Referrer-Policy", "unsafe-url").build())
                other.enqueue(MockResponse.Builder().body("ok").build())
                NativeDocumentTransport(pairing(gateway)).load(
                    external.url("/first").toString(), method, if (method == "POST") "a=1" else null, null,
                    referrerUrl = internal, referrerPolicy = policy, originUrl = internal,
                )
                assertNothingLeaks(external.takeRequest())
                assertNothingLeaks(other.takeRequest())
            }
        } } }
    }

    @Test fun refererForOtherDocumentsAndSameOriginRequestsKeepsTheirPolicy() {
        MockWebServer().use { gateway -> MockWebServer().use { external ->
            gateway.start(); external.start()
            val externalPage = external.url("/page?x=1").toString()
            val internal = gateway.url("/?session=s").toString()
            // A third-party document keeps normal referrer behaviour (cap is only for the paired origin's page).
            external.enqueue(MockResponse.Builder().body("ok").build())
            NativeDocumentTransport(pairing(gateway)).load(
                external.url("/next").toString(), "GET", null, null,
                referrerUrl = externalPage, referrerPolicy = "unsafe-url",
            )
            assertEquals(externalPage, external.takeRequest().headers["Referer"])
            // The paired origin's own page toward the paired origin: only the Gateway sees it.
            gateway.enqueue(MockResponse.Builder().body("ok").build())
            NativeDocumentTransport(pairing(gateway)).load(
                gateway.url("/other").toString(), "GET", null, null,
                referrerUrl = internal, referrerPolicy = "unsafe-url",
            )
            assertEquals(internal, gateway.takeRequest().headers["Referer"])
        } }
    }

    @Test fun formEncodingsAndMethodsAreConstrainedToTheStandardOnes() {
        MockWebServer().use { server ->
            server.start()
            val transport = NativeDocumentTransport(null)
            val url = server.url("/f").toString()
            val forged = listOf(
                "application/json", "APPLICATION/JSON", "application/json; charset=utf-8", "text/html",
                "application/octet-stream", "multipart/form-data", "multipart/form-data; boundary=",
                "multipart/form-data; boundary=a b", "multipart/form-data; boundary=x; foo=bar",
                "text/plain; foo=bar", "text/plain, application/json",
                "application/x-www-form-urlencoded, application/json", "", " ",
                "text/plain\r\nX-Pirc-Request: 1", "text/plain\nX-Pirc-Request: 1",
                "multipart/form-data; boundary=" + "a".repeat(71),
            )
            for (type in forged) {
                assertThrows(type, IllegalArgumentException::class.java) {
                    transport.load(url, "POST", "a=1", type)
                }
            }
            for (method in listOf("PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "TRACE", "dialog", "", " POST", "POST ")) {
                assertThrows(method, IllegalArgumentException::class.java) {
                    transport.load(url, method, null, null)
                }
            }
            assertEquals(0, server.requestCount)
            // The standard encodings, in any casing, still go out.
            for (type in listOf(
                "Text/Plain", "APPLICATION/X-WWW-FORM-URLENCODED; charset=UTF-8",
                "application/x-www-form-urlencoded;charset=\"utf-8\"", "MULTIPART/FORM-DATA; boundary=----WebKitFormBoundaryAbC123",
            )) {
                server.enqueue(MockResponse.Builder().body("ok").build())
                transport.load(url, "post", "a=1", type)
                assertEquals(type, server.takeRequest().headers["Content-Type"])
            }
        }
    }

    @Test fun navigationAndFormRequestsCannotCarryAuthoredHeaders() {
        MockWebServer().use { server ->
            server.start()
            val allowed = setOf(
                "accept", "host", "connection", "accept-encoding", "user-agent", "content-type", "content-length",
                "origin", "referer", "cookie", "cache-control", "pragma", "if-none-match", "if-modified-since",
            )
            val hostile = "x\r\nX-Pirc-Request: 1"
            fun check(block: () -> Unit) {
                server.enqueue(MockResponse.Builder().body("ok").build())
                runCatching(block)
                if (server.requestCount > 0) {
                    val names = server.takeRequest().headers.names().map { it.lowercase() }.toSet()
                    assertTrue(names.toString(), allowed.containsAll(names))
                }
            }
            val transport = NativeDocumentTransport(null)
            val base = server.url("/").toString()
            check { transport.load(server.url("/a\r\nX-Pirc-Request: 1").toString(), "GET", null, null) }
            check { transport.load("/a?b=${hostile}", "GET", null, null, base) }
            check { transport.load(server.url("/a").toString(), "GET", null, null, referrerUrl = hostile, referrerPolicy = hostile, originUrl = hostile) }
            check { transport.load(server.url("/a").toString(), "POST", "a=1", "text/plain", referrerUrl = base + hostile, originUrl = base + hostile) }
            assertThrows(IllegalArgumentException::class.java) {
                transport.load(server.url("/a").toString(), "GET", null, null, ifNoneMatch = hostile)
            }
            assertThrows(IllegalArgumentException::class.java) {
                transport.load(server.url("/a").toString(), "GET", null, null, ifModifiedSince = hostile)
            }
        }
    }

    @Test fun staleOrRevokedAppHandlesNeverCarryAnyCredential() {
        MockWebServer().use { gateway -> MockWebServer().use { other ->
            gateway.start(); other.start()
            val authority = AppRequestAuthority()
            val p = pairing(gateway)
            val handle = authority.issue(p)

            // Handle minted for one pairing does not authorize another server's credential.
            gateway.enqueue(MockResponse.Builder().body("{}").build())
            val different = Pairing(p.baseUrl, "another-device-token")
            NativeDocumentTransport(different, initiator = handle).load(gateway.url("/api/x").toString(), "GET", null, null)
            assertNull(gateway.takeRequest().headers["Authorization"])

            // Revoked handle (unpair / re-pair / stamp rotation) is useless afterwards.
            authority.revokeAll()
            gateway.enqueue(MockResponse.Builder().body("{}").build())
            NativeDocumentTransport(p, initiator = handle).load(gateway.url("/api/x").toString(), "GET", null, null)
            assertNull(gateway.takeRequest().headers["Authorization"])
            // A handle issued after the change is a fresh, working one.
            gateway.enqueue(MockResponse.Builder().body("{}").build())
            NativeDocumentTransport(p, initiator = authority.issue(p)).load(gateway.url("/api/x").toString(), "GET", null, null)
            assertEquals("Bearer device-token", gateway.takeRequest().headers["Authorization"])
        } }
    }

    @Test fun revocationBetweenRedirectHopsDropsTheCredentialForTheRestOfTheChain() {
        MockWebServer().use { gateway ->
            gateway.start()
            val authority = AppRequestAuthority()
            val p = pairing(gateway)
            val handle = authority.issue(p)
            gateway.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse =
                    if (request.target.startsWith("/api/first")) {
                        authority.revokeAll() // the account changes while the response is in flight
                        MockResponse.Builder().code(302).addHeader("Location", "/api/second").build()
                    } else MockResponse.Builder().body("{}").build()
            }
            NativeDocumentTransport(p, initiator = handle).load(gateway.url("/api/first").toString(), "GET", null, null)
            assertEquals("Bearer device-token", gateway.takeRequest().headers["Authorization"])
            assertNull(gateway.takeRequest().headers["Authorization"])
        }
    }

    private fun pairing(server: MockWebServer) =
        Pairing(server.url("/").toString().trimEnd('/'), "device-token")

    /** Test stand-in for a request the app itself started (the only way to carry the credential). */
    private fun appInitiated(pairing: Pairing) = AppRequestAuthority().issue(pairing)

    @Test fun cacheModesSetRestrictedHeadersAndConditionalValidators() {
        MockWebServer().use { server ->
            repeat(3) { server.enqueue(MockResponse.Builder().body("ok").build()) }
            server.start()

            val transport = NativeDocumentTransport(pairing(server))
            val url = server.url("/document").toString()
            transport.load(url, "GET", null, null)
            transport.load(
                url,
                "GET",
                null,
                null,
                cacheMode = NativeDocumentTransport.CacheMode.REVALIDATE,
                ifNoneMatch = "W/\"document-v1\"",
                ifModifiedSince = "Wed, 21 Oct 2015 07:28:00 GMT",
            )
            transport.load(
                url,
                "GET",
                null,
                null,
                cacheMode = NativeDocumentTransport.CacheMode.RELOAD,
                ifNoneMatch = "\"ignored-on-forced-reload\"",
                ifModifiedSince = "Wed, 21 Oct 2015 07:28:00 GMT",
            )

            val defaultRequest = server.takeRequest()
            assertNull(defaultRequest.headers["Cache-Control"])
            assertNull(defaultRequest.headers["Pragma"])
            assertNull(defaultRequest.headers["If-None-Match"])
            assertNull(defaultRequest.headers["If-Modified-Since"])

            val revalidateRequest = server.takeRequest()
            assertEquals("max-age=0", revalidateRequest.headers["Cache-Control"])
            assertNull(revalidateRequest.headers["Pragma"])
            assertEquals("W/\"document-v1\"", revalidateRequest.headers["If-None-Match"])
            assertEquals(
                "Wed, 21 Oct 2015 07:28:00 GMT",
                revalidateRequest.headers["If-Modified-Since"],
            )

            val reloadRequest = server.takeRequest()
            assertEquals("no-cache", reloadRequest.headers["Cache-Control"])
            assertEquals("no-cache", reloadRequest.headers["Pragma"])
            assertNull(reloadRequest.headers["If-None-Match"])
            assertNull(reloadRequest.headers["If-Modified-Since"])
            assertEquals(3, server.requestCount)
        }
    }

    @Test fun postRevalidationPreservesUtf8BodyAnd303GetCacheIntent() {
        MockWebServer().use { server ->
            server.enqueue(
                MockResponse.Builder()
                    .code(303)
                    .addHeader("Location", "/landed")
                    .build(),
            )
            server.enqueue(MockResponse.Builder().body("landed").build())
            server.start()

            val body = "text=你好&encoded=%7E"
            val result = NativeDocumentTransport(pairing(server)).load(
                server.url("/submit").toString(),
                "POST",
                body,
                formContentType,
                cacheMode = NativeDocumentTransport.CacheMode.REVALIDATE,
            )

            val post = server.takeRequest()
            assertEquals("POST", post.method)
            assertArrayEquals(
                body.toByteArray(Charsets.UTF_8),
                post.body?.toByteArray() ?: byteArrayOf(),
            )
            assertEquals("max-age=0", post.headers["Cache-Control"])
            assertNull(post.headers["Pragma"])
            assertNull(post.headers["If-None-Match"])
            assertNull(post.headers["If-Modified-Since"])

            val redirectedGet = server.takeRequest()
            assertEquals("GET", redirectedGet.method)
            assertEquals("/landed", redirectedGet.target)
            assertEquals("max-age=0", redirectedGet.headers["Cache-Control"])
            assertNull(redirectedGet.headers["Pragma"])
            assertNull(redirectedGet.headers["Content-Type"])
            assertNull(redirectedGet.headers["If-None-Match"])
            assertNull(redirectedGet.headers["If-Modified-Since"])
            assertEquals("GET", result["finalMethod"])
            assertEquals(server.url("/landed").toString(), result["finalUrl"])
            assertEquals(2, server.requestCount)
        }
    }

    @Test fun conditionalValidatorsStayOnTheInitialRepresentationUrl() {
        MockWebServer().use { gateway ->
            MockWebServer().use { external ->
                gateway.start()
                external.start()
                gateway.enqueue(
                    MockResponse.Builder()
                        .code(302)
                        .addHeader("Location", "#fresh")
                        .build(),
                )
                gateway.enqueue(MockResponse.Builder().body("fragment target").build())
                gateway.enqueue(
                    MockResponse.Builder()
                        .code(302)
                        .addHeader("Location", "/different")
                        .build(),
                )
                gateway.enqueue(MockResponse.Builder().body("same-origin target").build())
                gateway.enqueue(
                    MockResponse.Builder()
                        .code(302)
                        .addHeader("Location", external.url("/landing").toString())
                        .build(),
                )
                external.enqueue(MockResponse.Builder().body("external target").build())

                val transport = NativeDocumentTransport(pairing(gateway), initiator = appInitiated(pairing(gateway)))
                fun revalidate(path: String) = transport.load(
                    gateway.url(path).toString(),
                    "GET",
                    null,
                    null,
                    cacheMode = NativeDocumentTransport.CacheMode.REVALIDATE,
                    ifNoneMatch = "\"v1\"",
                    ifModifiedSince = "Wed, 21 Oct 2015 07:28:00 GMT",
                )
                revalidate("/fragment?raw=%7E#old")
                revalidate("/start")
                revalidate("/cross-origin")

                val fragmentStart = gateway.takeRequest()
                val fragmentFollow = gateway.takeRequest()
                assertEquals("/fragment?raw=%7E", fragmentStart.target)
                assertEquals("/fragment?raw=%7E", fragmentFollow.target)
                assertEquals("\"v1\"", fragmentStart.headers["If-None-Match"])
                assertEquals("\"v1\"", fragmentFollow.headers["If-None-Match"])
                assertEquals(
                    "Wed, 21 Oct 2015 07:28:00 GMT",
                    fragmentFollow.headers["If-Modified-Since"],
                )

                val sameOriginStart = gateway.takeRequest()
                val sameOriginFollow = gateway.takeRequest()
                assertEquals("\"v1\"", sameOriginStart.headers["If-None-Match"])
                assertNull(sameOriginFollow.headers["If-None-Match"])
                assertNull(sameOriginFollow.headers["If-Modified-Since"])
                assertEquals("Bearer device-token", sameOriginFollow.headers["Authorization"])

                val crossOriginStart = gateway.takeRequest()
                val crossOriginFollow = external.takeRequest()
                assertEquals("\"v1\"", crossOriginStart.headers["If-None-Match"])
                assertNull(crossOriginFollow.headers["If-None-Match"])
                assertNull(crossOriginFollow.headers["If-Modified-Since"])
                assertNull(crossOriginFollow.headers["Authorization"])
                assertEquals(5, gateway.requestCount)
                assertEquals(1, external.requestCount)
            }
        }
    }

    @Test fun notModifiedResponsesReturnEmptyBytesAndCacheMetadata() {
        MockWebServer().use { server ->
            server.enqueue(
                MockResponse.Builder()
                    .code(304)
                    .addHeader("ETag", "\"v1\"")
                    .addHeader("ETag", "\"v2\"")
                    .addHeader("Last-Modified", "Wed, 21 Oct 2015 07:28:00 GMT")
                    .addHeader("Date", "Mon, 06 Nov 2023 08:49:37 GMT")
                    .addHeader("Age", "12")
                    .addHeader("Expires", "Mon, 06 Nov 2023 09:49:37 GMT")
                    .addHeader("Cache-Control", "public, max-age=3600")
                    .addHeader("Cache-Control", "must-revalidate")
                    .addHeader("Vary", "Accept")
                    .addHeader("Vary", "Accept-Language")
                    .addHeader("Referrer-Policy", "no-referrer, invalid-policy")
                    .addHeader("Referrer-Policy", "origin")
                    .body("304 bodies are not document bytes")
                    .build(),
            )
            server.start()

            val result = NativeDocumentTransport(null).load(
                server.url("/cached").toString(),
                "GET",
                null,
                null,
                cacheMode = NativeDocumentTransport.CacheMode.REVALIDATE,
                ifNoneMatch = "\"v1\"",
            )

            assertEquals(304, result["status"])
            assertArrayEquals(byteArrayOf(), result["bytes"] as ByteArray)
            val headers = result["headersRelevant"] as Map<*, *>
            assertNull(headers["ETag"])
            assertEquals("Wed, 21 Oct 2015 07:28:00 GMT", headers["Last-Modified"])
            assertEquals("Mon, 06 Nov 2023 08:49:37 GMT", headers["Date"])
            assertEquals("12", headers["Age"])
            assertEquals("Mon, 06 Nov 2023 09:49:37 GMT", headers["Expires"])
            assertEquals(
                "public, max-age=3600, must-revalidate",
                headers["Cache-Control"],
            )
            assertEquals("Accept, Accept-Language", headers["Vary"])
            assertEquals("no-referrer, invalid-policy, origin", headers["Referrer-Policy"])
            assertEquals("\"v1\"", server.takeRequest().headers["If-None-Match"])
            val requestSentAt = result["requestSentAt"] as Long
            val receivedAt = result["receivedAt"] as Long
            assertTrue(requestSentAt > 0)
            assertTrue(receivedAt >= requestSentAt)
        }
    }

    @Test fun cacheModeAndConditionalHeaderArgumentsAreRestricted() {
        MockWebServer().use { server ->
            server.start()
            val transport = NativeDocumentTransport(null)
            val url = server.url("/document").toString()

            assertThrows(IllegalArgumentException::class.java) {
                transport.load(
                    url,
                    "POST",
                    "x=1",
                    formContentType,
                    cacheMode = NativeDocumentTransport.CacheMode.RELOAD,
                )
            }
            assertThrows(IllegalArgumentException::class.java) {
                transport.load(
                    url,
                    "POST",
                    "x=1",
                    formContentType,
                    ifNoneMatch = "\"v1\"",
                )
            }
            assertThrows(IllegalArgumentException::class.java) {
                transport.load(url, "GET", null, null, ifNoneMatch = "valid\r\nInjected: yes")
            }
            assertThrows(IllegalArgumentException::class.java) {
                transport.load(
                    url,
                    "GET",
                    null,
                    null,
                    ifModifiedSince = "x".repeat(8 * 1024 + 1),
                )
            }
            assertEquals(0, server.requestCount)
        }
    }

    @Test fun postUsesUtf8BodyRelativeBaseAndReturnsDocumentMetadata() {
        MockWebServer().use { server ->
            server.enqueue(
                MockResponse.Builder()
                    .addHeader("Content-Type", "TEXT/HTML; charset=utf-8")
                    .addHeader("Content-Disposition", "inline; filename=page.html")
                    .addHeader("Refresh", "0; url=/next")
                    .body("<h1>saved</h1>")
                    .build(),
            )
            server.start()

            val body = "text=你好&encoded=%7E"
            val base = server.url("/forms/current?old=1").toString()
            val result = NativeDocumentTransport(pairing(server), initiator = appInitiated(pairing(server))).load(
                "submit?key=%7E",
                "POST",
                body,
                formContentType,
                base,
            )

            val request = server.takeRequest()
            assertEquals("POST", request.method)
            assertEquals("/forms/submit?key=%7E", request.target)
            assertArrayEquals(body.toByteArray(Charsets.UTF_8), request.body?.toByteArray() ?: byteArrayOf())
            assertEquals(formContentType, request.headers["Content-Type"])
            assertEquals(
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                request.headers["Accept"],
            )
            assertEquals("Bearer device-token", request.headers["Authorization"])

            assertEquals(200, result["status"])
            assertEquals("POST", result["finalMethod"])
            assertEquals("<h1>saved</h1>", String(result["bytes"] as ByteArray, Charsets.UTF_8))
            assertEquals("text/html", result["mimeType"])
            assertEquals("UTF-8", result["charset"])
            assertEquals(server.url("/forms/submit?key=%7E").toString(), result["finalUrl"])
            val headers = result["headersRelevant"] as Map<*, *>
            assertEquals("TEXT/HTML; charset=utf-8", headers["Content-Type"])
            assertEquals("inline; filename=page.html", headers["Content-Disposition"])
            assertEquals("0; url=/next", headers["Refresh"])
        }
    }

    @Test fun stylesheetRequestsUseCssAcceptAndRejectPost() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse.Builder().body("p { color: red }").build())
            server.start()

            val transport = NativeDocumentTransport(pairing(server), initiator = appInitiated(pairing(server)))
            val result = transport.load(
                server.url("/style.css").toString(),
                "GET",
                null,
                null,
                resourceType = NativeDocumentTransport.ResourceType.STYLESHEET,
                referrerUrl = "https://source.example.test/private?token=1",
                referrerPolicy = "unsafe-url",
            )
            val request = server.takeRequest()

            assertEquals("GET", request.method)
            assertEquals("text/css,*/*;q=0.1", request.headers["Accept"])
            assertEquals("p { color: red }", String(result["bytes"] as ByteArray, Charsets.UTF_8))
            assertEquals("Bearer device-token", request.headers["Authorization"])
            assertNull(request.headers["Referer"])
            assertNull(request.headers["Origin"])
            assertEquals("", result["requestReferrer"])
            assertEquals("no-referrer", result["requestReferrerPolicy"])
            assertNull(result["requestOrigin"])
            assertEquals("null", result["requestOriginSource"])
            assertThrows(IllegalArgumentException::class.java) {
                transport.load(
                    server.url("/style.css").toString(),
                    "POST",
                    "x=1",
                    formContentType,
                    resourceType = NativeDocumentTransport.ResourceType.STYLESHEET,
                )
            }
            assertEquals(1, server.requestCount)
        }
    }

    @Test fun redirectsApplyPostMethodRules() {
        for (code in listOf(301, 302, 303, 307, 308)) {
            MockWebServer().use { server ->
                server.enqueue(
                    MockResponse.Builder()
                        .code(code)
                        .addHeader("Location", "../final")
                        .build(),
                )
                server.enqueue(MockResponse.Builder().body("ok").build())
                server.start()

                val formBody = "name=%E4%B8%AD"
                val result = NativeDocumentTransport(pairing(server), initiator = appInitiated(pairing(server))).load(
                    server.url("/forms/start").toString(),
                    "POST",
                    formBody,
                    formContentType,
                )

                val first = server.takeRequest()
                val second = server.takeRequest()
                assertEquals("POST", first.method)
                assertEquals("/forms/start", first.target)
                assertEquals("/final", second.target)
                assertEquals("Bearer device-token", first.headers["Authorization"])
                assertEquals("Bearer device-token", second.headers["Authorization"])

                if (code == 307 || code == 308) {
                    assertEquals("POST", result["finalMethod"])
                    assertEquals("POST", second.method)
                    assertEquals(formContentType, second.headers["Content-Type"])
                    assertEquals(formBody, second.body?.utf8())
                } else {
                    assertEquals("GET", result["finalMethod"])
                    assertEquals("GET", second.method)
                    assertNull(second.headers["Content-Type"])
                    assertEquals("", second.body?.utf8() ?: "")
                }
            }
        }
    }

    @Test fun injectedClientRedirectsAreHandledWithoutCrossOriginBearerOrCookieHeaders() {
        MockWebServer().use { gateway ->
            MockWebServer().use { external ->
                gateway.start()
                external.start()
                gateway.enqueue(
                    MockResponse.Builder()
                        .code(307)
                        .addHeader("Location", external.url("/landing"))
                        .build(),
                )
                external.enqueue(MockResponse.Builder().body("external page").build())

                val injectedClient = OkHttpClient.Builder()
                    .followRedirects(true)
                    .followSslRedirects(true)
                    .retryOnConnectionFailure(true)
                    .build()
                NativeDocumentTransport(pairing(gateway), injectedClient, initiator = appInitiated(pairing(gateway))).load(
                    gateway.url("/start").toString(),
                    "POST",
                    "x=1",
                    formContentType,
                )

                val first = gateway.takeRequest()
                val second = external.takeRequest()
                assertEquals("Bearer device-token", first.headers["Authorization"])
                assertNull(first.headers["Cookie"])
                assertEquals("POST", second.method)
                assertEquals("x=1", second.body?.utf8())
                assertNull(second.headers["Authorization"])
                assertNull(second.headers["Cookie"])
                assertEquals(1, gateway.requestCount)
                assertEquals(1, external.requestCount)
            }
        }
    }

    @Test fun postIsNotRetriedWhenAnInjectedClientWouldRetry() {
        MockWebServer().use { server ->
            server.enqueue(
                MockResponse.Builder()
                    .onResponseStart(SocketEffect.CloseSocket())
                    .build(),
            )
            server.enqueue(MockResponse.Builder().body("must not be replayed").build())
            server.start()

            val injectedClient = OkHttpClient.Builder()
                .retryOnConnectionFailure(true)
                .build()
            assertThrows(IOException::class.java) {
                NativeDocumentTransport(null, injectedClient).load(
                    server.url("/mutate").toString(),
                    "POST",
                    "one-shot=body",
                    formContentType,
                )
            }
            assertEquals(1, server.requestCount)
        }
    }

    @Test fun relativeAndEmptyUrlsResolveAgainstCurrentDocumentWithoutNormalizingEncodedQuery() {
        MockWebServer().use { gateway ->
            MockWebServer().use { external ->
                external.enqueue(MockResponse.Builder().body("relative").build())
                external.enqueue(MockResponse.Builder().body("same document").build())
                gateway.start()
                external.start()

                val transport = NativeDocumentTransport(pairing(gateway))
                val base = external.url("/dir/page?existing=%7E").toString()
                transport.load("action?value=%7E", "GET", null, null, base)
                transport.load("", "GET", null, null, base)

                assertEquals("/dir/action?value=%7E", external.takeRequest().target)
                assertEquals("/dir/page?existing=%7E", external.takeRequest().target)
                assertEquals(2, external.requestCount)
                assertEquals(0, gateway.requestCount)
            }
        }
    }

    @Test fun resolveUrlAcceptsIpv6LiteralsAndIdnHosts() {
        val transport = NativeDocumentTransport(null)

        assertEquals(
            "http://[::1]:8080/dest?value=%7E",
            transport.resolveUrl("../dest?value=%7E", "http://[::1]:8080/a/b"),
        )
        assertEquals(
            "https://xn--bcher-kva.example/resource",
            transport.resolveUrl("/resource", "https://bücher.example/current/page"),
        )
    }

    @Test fun blobBaseAllowsOnlyAbsoluteHttpUrlsWithoutPairingFallback() {
        MockWebServer().use { gateway ->
            gateway.start()
            val transport = NativeDocumentTransport(pairing(gateway))
            val blobBase = "blob:${gateway.url("/object/nonce/id")}"
            val absolute = gateway.url("/absolute-resource").toString()

            assertEquals(absolute, transport.resolveUrl(absolute, blobBase))
            listOf(
                "/relative-resource",
                "images/resource.png",
                "//cdn.example/resource.png",
                "data:text/plain,resource",
            ).forEach { source ->
                assertThrows(IllegalArgumentException::class.java) {
                    transport.resolveUrl(source, blobBase)
                }
            }
            assertThrows(IllegalArgumentException::class.java) {
                transport.resolveUrl(absolute, "blob:file:///tmp/object")
            }
            assertThrows(IllegalArgumentException::class.java) {
                transport.resolveUrl(absolute, "not-a-base")
            }
            assertEquals(0, gateway.requestCount)
        }
    }

    @Test fun resolveUrlAppliesHtmlBaseHrefAndPreservesRawEscapesAndFragments() {
        val transport = NativeDocumentTransport(null)
        val documentUrl = "https://docs.example/manual/page.html?old=%7E"
        val effectiveBase = transport.resolveUrl("../assets/", documentUrl)

        assertEquals("https://docs.example/assets/", effectiveBase)
        val destination = transport.resolveUrl("submit?value=%7E", effectiveBase)
        assertEquals("https://docs.example/assets/submit?value=%7E", destination)
        assertEquals(
            "https://docs.example/assets/submit?value=%7E#result",
            transport.resolveUrl("#result", destination),
        )
    }

    @Test fun redirectsInheritFragmentsUnlessLocationExplicitlySuppliesOne() {
        MockWebServer().use { server ->
            server.start()
            for (location in listOf("/inherited", "/cleared#", "/explicit#new")) {
                server.enqueue(
                    MockResponse.Builder()
                        .code(302)
                        .addHeader("Location", location)
                        .build(),
                )
                server.enqueue(MockResponse.Builder().body("done").build())
            }

            val transport = NativeDocumentTransport(null)
            val inherited = transport.load(server.url("/from#keep").toString(), "GET", null, null)
            val cleared = transport.load(server.url("/from#drop").toString(), "GET", null, null)
            val replaced = transport.load(server.url("/from#old").toString(), "GET", null, null)

            assertEquals(server.url("/inherited#keep").toString(), inherited["finalUrl"])
            assertEquals(server.url("/cleared#").toString(), cleared["finalUrl"])
            assertEquals(server.url("/explicit#new").toString(), replaced["finalUrl"])
            assertEquals(listOf("/from", "/inherited", "/from", "/cleared", "/from", "/explicit"),
                List(6) { server.takeRequest().target })
        }
    }

    @Test fun errorStatusesKeepTheirBodiesAndEmptyStatusesRemainAvailableToCaller() {
        MockWebServer().use { server ->
            for (code in listOf(403, 500)) {
                server.enqueue(
                    MockResponse.Builder()
                        .code(code)
                        .addHeader("Content-Type", "text/plain; charset=UTF-8")
                        .addHeader("Location", "/help")
                        .body("error-$code")
                        .build(),
                )
            }
            for (code in listOf(204, 205)) {
                server.enqueue(
                    MockResponse.Builder()
                        .code(code)
                        .build(),
                )
            }
            server.start()

            val transport = NativeDocumentTransport(null)
            for (code in listOf(403, 500)) {
                val result = transport.load(server.url("/error").toString(), "GET", null, null)
                assertEquals(code, result["status"])
                assertEquals("error-$code", String(result["bytes"] as ByteArray, Charsets.UTF_8))
                assertEquals("/help", (result["headersRelevant"] as Map<*, *>)["Location"])
            }
            for (code in listOf(204, 205)) {
                val result = transport.load(server.url("/empty").toString(), "GET", null, null)
                assertEquals(code, result["status"])
                assertArrayEquals(byteArrayOf(), result["bytes"] as ByteArray)
            }
        }
    }

    @Test fun declaredAndUnknownLengthsReadFailuresAndRedirectLoopsAreBounded() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse.Builder().body("12345").build())
            server.enqueue(MockResponse.Builder().chunkedBody("12345", 2).build())
            server.enqueue(
                MockResponse.Builder()
                    .body(
                        object : MockResponseBody {
                            override val contentLength: Long = -1

                            override fun writeTo(sink: BufferedSink) {
                                sink.writeUtf8("1234")
                                sink.flush()
                                throw IOException("synthetic response body read failure")
                            }
                        },
                    )
                    .build(),
            )
            repeat(11) {
                server.enqueue(
                    MockResponse.Builder()
                        .code(302)
                        .addHeader("Location", "/loop")
                        .build(),
                )
            }
            server.start()

            val client = OkHttpClient.Builder().readTimeout(1, TimeUnit.SECONDS).build()
            val transport = NativeDocumentTransport(null, client, limit = 4)
            assertThrows(IllegalStateException::class.java) {
                transport.load(server.url("/declared").toString(), "GET", null, null)
            }
            assertThrows(IllegalStateException::class.java) {
                transport.load(server.url("/chunked").toString(), "GET", null, null)
            }
            assertThrows(IOException::class.java) {
                transport.load(server.url("/read-failure").toString(), "GET", null, null)
            }
            assertThrows(IllegalStateException::class.java) {
                transport.load(server.url("/loop").toString(), "GET", null, null)
            }
            assertEquals(14, server.requestCount)
        }
    }

    @Test fun userInfoAndUnsupportedProtocolsAreRejectedBeforeSending() {
        MockWebServer().use { server ->
            server.start()
            val transport = NativeDocumentTransport(null)
            val address = server.url("/private").toString()

            assertThrows(IllegalArgumentException::class.java) {
                transport.load(address.replace("://", "://user:secret@"), "GET", null, null)
            }
            assertThrows(IllegalArgumentException::class.java) {
                transport.resolveUrl(address.replace("://", "://user:secret@"))
            }
            assertThrows(IllegalArgumentException::class.java) {
                transport.load("ftp://example.test/file", "GET", null, null)
            }
            assertThrows(IllegalArgumentException::class.java) {
                transport.resolveUrl("ftp://example.test/file")
            }
            assertEquals(0, server.requestCount)
        }
    }
}
