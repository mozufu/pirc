package org.mozufu.pirc.scripts

import java.util.concurrent.TimeUnit
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mozufu.pirc.call
import org.mozufu.pirc.direct
import org.robolectric.RobolectricTestRunner

/**
 * Requests of message documents go out without credentials (plans/roadmap.md M8 step 6). The
 * test server runs on this machine, which the real policy refuses; these tests allow it, except
 * the one that checks the refusal.
 */
@RunWith(RobolectricTestRunner::class)
class ScriptResourcesTest {
    private val server = MockWebServer()
    private val engine = FakeEngine()
    private val scripts = DocumentScripts(engine, resources = ScriptResources(addressPolicy = { true }))
    private val channel = ScriptsChannel(scripts, work = direct, network = direct, control = direct, reply = direct)
    private var id = 0

    @Before fun start() {
        server.start()
        id = (channel.call("open", mapOf("owner" to "doc")).value as Map<*, *>)["id"] as Int
    }

    @After fun stop() = server.close()

    private fun fetch(request: Map<String, Any?>) =
        channel.call("resource", mapOf("id" to id, "owner" to "doc", "request" to mapOf("id" to "fetch-1") + request))

    private fun cors(body: String = "ok") = MockResponse.Builder().code(200)
        .addHeader("Access-Control-Allow-Origin", "*")
        .addHeader("Content-Type", "text/plain; charset=utf-8")
        .addHeader("Set-Cookie", "tracker=1")
        .addHeader("X-Private", "secret")
        .body(body).build()

    @Test fun requestsCarryNoCredentialsAndNoReferrer() {
        server.enqueue(cors())
        server.enqueue(cors())
        val answer = fetch(mapOf("url" to server.url("/a").toString(), "headers" to listOf(listOf("Accept", "text/plain"))))
        assertNull(answer.errorCode)
        val response = answer.value as Map<*, *>
        assertEquals(200, response["status"])
        assertEquals("cors", response["type"])
        assertArrayEquals("ok".toByteArray(), response["bodyBytes"] as ByteArray)
        // Only safelisted response headers reach the script; Set-Cookie never does.
        val names = (response["headers"] as List<*>).map { (it as List<*>)[0] }
        assertEquals(listOf("content-length", "content-type"), names)
        val first = server.takeRequest()
        assertNull(first.headers["Authorization"])
        assertNull(first.headers["Cookie"])
        assertNull(first.headers["Referer"])
        assertEquals("null", first.headers["Origin"])
        // The response's cookie is not kept: the next request has none either.
        fetch(mapOf("url" to server.url("/b").toString()))
        assertNull(server.takeRequest().headers["Cookie"])
    }

    @Test fun aScriptCannotSendCredentials() {
        for (header in listOf("Authorization", "Cookie", "Proxy-Authorization", "authorization")) {
            val answer = fetch(mapOf("url" to server.url("/").toString(), "headers" to listOf(listOf(header, "Bearer pirc_dev_token"))))
            assertEquals(header, "RESOURCE", answer.errorCode)
        }
        assertEquals(0, server.requestCount)
    }

    @Test fun forbiddenHeadersAreTheClientsToSet() {
        server.enqueue(cors())
        fetch(mapOf("url" to server.url("/").toString(), "headers" to listOf(
            listOf("Origin", "https://gateway.example"), listOf("Referer", "https://gateway.example/"),
            listOf("Host", "gateway.example"),
        )))
        val request = server.takeRequest()
        assertEquals("null", request.headers["Origin"])
        assertNull(request.headers["Referer"])
        assertTrue(request.headers["Host"]!!.startsWith(server.hostName))
    }

    @Test fun crossOriginReadsNeedCors() {
        server.enqueue(MockResponse.Builder().code(200).body("private").build())
        assertEquals("RESOURCE", fetch(mapOf("url" to server.url("/").toString())).errorCode)
        // no-cors gives an opaque response: nothing readable.
        server.enqueue(MockResponse.Builder().code(200).body("private").build())
        val opaque = fetch(mapOf("url" to server.url("/").toString(), "mode" to "no-cors")).value as Map<*, *>
        assertEquals("opaque", opaque["type"])
        assertEquals(0, opaque["status"])
        assertNull(opaque["bodyBytes"])
    }

    @Test fun nonSimpleRequestsArePreflighted() {
        server.enqueue(MockResponse.Builder().code(204)
            .addHeader("Access-Control-Allow-Origin", "null")
            .addHeader("Access-Control-Allow-Methods", "PUT")
            .addHeader("Access-Control-Allow-Headers", "x-custom").build())
        server.enqueue(cors())
        val answer = fetch(mapOf(
            "url" to server.url("/put").toString(), "method" to "PUT", "bodyBytes" to "x".toByteArray(),
            "headers" to listOf(listOf("X-Custom", "1")),
        ))
        assertNull(answer.errorCode)
        val preflight = server.takeRequest()
        assertEquals("OPTIONS", preflight.method)
        assertEquals("PUT", preflight.headers["Access-Control-Request-Method"])
        assertEquals("x-custom", preflight.headers["Access-Control-Request-Headers"])
        assertEquals("PUT", server.takeRequest().method)
        // A preflight that does not allow it stops the request.
        server.enqueue(MockResponse.Builder().code(204).addHeader("Access-Control-Allow-Origin", "*").build())
        assertEquals("RESOURCE", fetch(mapOf("url" to server.url("/").toString(), "method" to "DELETE")).errorCode)
        assertEquals("OPTIONS", server.takeRequest().method)
        assertEquals(3, server.requestCount)
    }

    @Test fun redirectsAreFollowedWithoutCredentials() {
        server.enqueue(MockResponse.Builder().code(302).addHeader("Location", "/next")
            .addHeader("Access-Control-Allow-Origin", "*").build())
        server.enqueue(cors("moved"))
        val response = fetch(mapOf("url" to server.url("/start").toString())).value as Map<*, *>
        assertEquals(true, response["redirected"])
        assertTrue((response["url"] as String).endsWith("/next"))
        server.takeRequest()
        val next = server.takeRequest()
        assertNull(next.headers["Authorization"])
        assertEquals("null", next.headers["Origin"])
    }

    @Test fun onlyAbsoluteHttpUrls() {
        for (url in listOf("/relative", "api/data", "file:///etc/hosts", "content://x/y", "javascript:1", "data:text/plain,x")) {
            assertEquals(url, "RESOURCE", fetch(mapOf("url" to url)).errorCode)
        }
        assertEquals(0, server.requestCount)
    }

    @Test fun theRealPolicyRefusesThisDeviceAndTheLocalNetwork() {
        val strict = DocumentScripts(engine)
        val strictChannel = ScriptsChannel(strict, work = direct, network = direct, control = direct, reply = direct)
        val opened = (strictChannel.call("open", mapOf("owner" to "strict")).value as Map<*, *>)["id"]
        server.enqueue(cors())
        val answer = strictChannel.call("resource", mapOf("id" to opened, "owner" to "strict", "request" to mapOf(
            "id" to "fetch-1", "url" to server.url("/").toString(),
        )))
        assertEquals("RESOURCE", answer.errorCode)
        assertEquals("RESOURCE", strictChannel.call("media", mapOf("url" to server.url("/a.mp3").toString(), "requestId" to "m")).errorCode)
        // An address written in the URL is never looked up, so it is checked on its own;
        // numeric forms that resolvers read differently are refused outright.
        for (host in listOf(
            "127.0.0.1", "[::1]", "127.1", "2130706433", "0177.0.0.1", "127.0.0.1.", "100",
            "[::ffff:127.0.0.1]", "[::127.0.0.1]",
        )) {
            val literal = "http://$host:${server.port}/"
            val refused = strictChannel.call("resource", mapOf("id" to opened, "owner" to "strict", "request" to mapOf(
                "id" to "fetch-2", "url" to literal,
            )))
            assertEquals(literal, "RESOURCE", refused.errorCode)
            assertEquals(literal, "RESOURCE", strictChannel.call("media", mapOf("url" to literal, "requestId" to "m")).errorCode)
        }
        assertEquals(0, server.requestCount)
    }

    @Test fun closingTheDocumentCancelsItsRequests() {
        server.enqueue(cors().newBuilder().headersDelay(5, TimeUnit.SECONDS).build())
        val result = arrayOfNulls<String>(1)
        val slow = Thread {
            result[0] = fetch(mapOf("url" to server.url("/slow").toString())).errorCode
        }
        slow.start()
        server.takeRequest(5, TimeUnit.SECONDS)
        channel.call("close", mapOf("id" to id, "owner" to "doc"))
        slow.join(5_000)
        assertEquals("RESOURCE", result[0])
    }

    @Test fun closingTheDocumentStopsABodyStillArriving() {
        server.enqueue(cors("late").newBuilder().bodyDelay(10, TimeUnit.SECONDS).build())
        val result = arrayOfNulls<String>(1)
        val slow = Thread { result[0] = fetch(mapOf("url" to server.url("/slow-body").toString())).errorCode }
        slow.start()
        server.takeRequest(5, TimeUnit.SECONDS)
        // The headers are back at once; give the client time to start reading the body.
        Thread.sleep(500)
        channel.call("close", mapOf("id" to id, "owner" to "doc"))
        slow.join(5_000)
        assertFalse(slow.isAlive)
        assertEquals("RESOURCE", result[0])
    }

    @Test fun aCancelledRequestKeepsItsIdUntilItEnds() {
        val client = okhttp3.OkHttpClient()
        fun newCall() = client.newCall(okhttp3.Request.Builder().url("http://example.invalid/").build())
        fun refusal(action: () -> Unit) = (runCatching(action).exceptionOrNull() as ScriptFailure).code
        val calls = ScriptResources.Calls()
        calls.begin("a")
        calls.cancel("a")
        // The cancelled request still runs: its ID is not free, and its next hop is refused.
        assertEquals("RESOURCE", refusal { calls.begin("a") })
        val hop = newCall()
        assertEquals("RESOURCE", refusal { calls.register("a", hop) })
        assertTrue(hop.isCanceled())
        // Once it ends, the ID can be used again, and the new request is not cancelled.
        calls.end("a")
        calls.begin("a")
        val fresh = newCall()
        calls.register("a", fresh)
        assertFalse(fresh.isCanceled())
        calls.done("a", fresh)
        calls.end("a")
        // Cancelled requests count against the cap until they end.
        val ids = (1..ScriptResources.MAX_IN_FLIGHT).map { "r$it" }
        ids.forEach(calls::begin)
        calls.cancelAll()
        assertEquals("RESOURCE", refusal { calls.begin("more") })
        ids.forEach(calls::end)
        calls.begin("more")
        calls.end("more")
    }

    @Test fun aCancelThatArrivesBeforeItsRequestRefusesIt() {
        fun refusal(action: () -> Unit) = (runCatching(action).exceptionOrNull() as? ScriptFailure)?.code
        var now = 0L
        val calls = ScriptResources.Calls(clock = { now })
        // The cancel ran on the control pool before the request reached the network pool.
        calls.cancel("fetch-1")
        assertEquals("RESOURCE", refusal { calls.begin("fetch-1") })
        // Refused once: the ID is free again afterwards.
        calls.begin("fetch-1")
        calls.end("fetch-1")
        // An old early cancel is forgotten.
        calls.cancel("fetch-2")
        now += ScriptResources.EARLY_CANCEL_NANOS + 1
        assertNull(refusal { calls.begin("fetch-2") })
        calls.end("fetch-2")
        // Only a bounded number of early cancels are kept, oldest first out.
        (0..ScriptResources.MAX_EARLY_CANCELS).forEach { calls.cancel("x$it") }
        assertNull(refusal { calls.begin("x0") })
        calls.end("x0")
        assertEquals("RESOURCE", refusal { calls.begin("x1") })
    }

    @Test fun mediaRedirectsAreFollowedHopByHop() {
        server.enqueue(MockResponse.Builder().code(302).addHeader("Location", "/real.mp3").build())
        server.enqueue(MockResponse.Builder().code(200).addHeader("Content-Type", "audio/mpeg").body("ID3").build())
        val media = channel.call("media", mapOf("url" to server.url("/a.mp3").toString(), "requestId" to "m1")).value as Map<*, *>
        assertArrayEquals("ID3".toByteArray(), media["bytes"] as ByteArray)
        server.takeRequest()
        assertEquals("/real.mp3", server.takeRequest().url.encodedPath)
    }

    @Test fun tappedMediaLoadsWithoutCredentials() {
        server.enqueue(MockResponse.Builder().code(200).addHeader("Content-Type", "audio/mpeg").body("ID3").build())
        val media = channel.call("media", mapOf("url" to server.url("/a.mp3").toString(), "requestId" to "m1")).value as Map<*, *>
        assertEquals("audio/mpeg", media["mimeType"])
        assertArrayEquals("ID3".toByteArray(), media["bytes"] as ByteArray)
        val request = server.takeRequest()
        assertNull(request.headers["Authorization"])
        assertNull(request.headers["Cookie"])
        assertNull(request.headers["Referer"])
    }

    @Test fun theSocketRefusesAPrivateAddressWhateverTheUrlSaid() {
        val sockets = ScriptResources.PolicySocketFactory(ScriptResources::isPublicAddress)
        val refused = runCatching {
            sockets.createSocket().use { it.connect(java.net.InetSocketAddress(java.net.InetAddress.getByName("127.0.0.1"), server.port)) }
        }.exceptionOrNull()
        assertTrue(refused is java.io.IOException)
        assertEquals(0, server.requestCount)
    }

    @Test fun mediaStillWorksAfterCloseAll() {
        channel.call("closeAll")
        server.enqueue(MockResponse.Builder().code(200).addHeader("Content-Type", "audio/mpeg").body("ID3").build())
        val answer = channel.call("media", mapOf("url" to server.url("/a.mp3").toString(), "requestId" to "m1"))
        assertNull(answer.errorCode)
        assertArrayEquals("ID3".toByteArray(), (answer.value as Map<*, *>)["bytes"] as ByteArray)
    }

    @Test fun aRequestIdCannotBeUsedTwiceAtOnce() {
        server.enqueue(cors().newBuilder().headersDelay(2, TimeUnit.SECONDS).build())
        val first = arrayOfNulls<String>(1)
        val slow = Thread { first[0] = fetch(mapOf("url" to server.url("/slow").toString())).errorCode }
        slow.start()
        server.takeRequest(5, TimeUnit.SECONDS)
        assertEquals("RESOURCE", fetch(mapOf("url" to server.url("/again").toString())).errorCode)
        assertEquals("INVALID", channel.call("resource", mapOf("id" to id, "owner" to "doc", "request" to mapOf(
            "id" to "bad id/with spaces", "url" to server.url("/").toString(),
        ))).errorCode)
        slow.join(5_000)
        assertNull(first[0])
        assertEquals(1, server.requestCount)
    }

    @Test fun cancellingARequestCancelsItsPreflight() {
        server.enqueue(MockResponse.Builder().code(204).headersDelay(5, TimeUnit.SECONDS)
            .addHeader("Access-Control-Allow-Origin", "*").addHeader("Access-Control-Allow-Methods", "PUT").build())
        val result = arrayOfNulls<String>(1)
        val slow = Thread {
            result[0] = fetch(mapOf("url" to server.url("/put").toString(), "method" to "PUT")).errorCode
        }
        slow.start()
        assertEquals("OPTIONS", server.takeRequest(5, TimeUnit.SECONDS)!!.method)
        channel.call("resourceCancel", mapOf("id" to id, "owner" to "doc", "requestId" to "fetch-1"))
        slow.join(5_000)
        assertEquals("RESOURCE", result[0])
        assertEquals(1, server.requestCount)
    }

    @Test fun aRedirectToGetDropsTheBodyHeaders() {
        server.enqueue(MockResponse.Builder().code(303).addHeader("Location", "/next")
            .addHeader("Access-Control-Allow-Origin", "*").build())
        server.enqueue(cors())
        fetch(mapOf(
            "url" to server.url("/post").toString(), "method" to "POST", "bodyBytes" to "a=1".toByteArray(),
            "headers" to listOf(listOf("Content-Type", "text/plain")),
        ))
        assertEquals("text/plain", server.takeRequest().headers["Content-Type"])
        val next = server.takeRequest()
        assertEquals("GET", next.method)
        assertNull(next.headers["Content-Type"])
    }
}
