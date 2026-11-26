package org.mozufu.pirc.background

import java.io.IOException
import java.net.InetSocketAddress
import java.net.Proxy
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.SocketEffect
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Robolectric gives the real org.json; the requests go to a local MockWebServer. */
@RunWith(RobolectricTestRunner::class)
class BackgroundClientTest {
    private val server = MockWebServer()
    private var token: String? = "pirc_dev_old"

    @Before fun start() = server.start()

    @After fun stop() = server.close()

    private fun client(http: OkHttpClient = GatewayHttp.client()) = BackgroundClient(
        gateway = server.url("/"),
        clientId = "client-1",
        tokens = { token },
        http = http,
        newCommandId = { "command-1" },
    )

    private fun enqueue(code: Int, body: String = "", vararg headers: Pair<String, String>) {
        server.enqueue(
            MockResponse.Builder().code(code).body(body)
                .apply { headers.forEach { (name, value) -> addHeader(name, value) } }
                .build(),
        )
    }

    @Test fun readsTheCompactRoutesWithTheClientHeaders() {
        enqueue(200, """{"state":"pending","epoch":3}""")
        enqueue(200, """{"run":{"id":"r 1"}}""")
        val client = client()

        val interaction = client.interaction("s/1", "i1") as BackgroundResult.Done
        assertEquals("pending", interaction.body!!.getString("state"))
        val get = server.takeRequest()
        assertEquals("GET", get.method)
        assertEquals("/api/sessions/s%2F1/interactions/i1", get.url.encodedPath)
        assertEquals("Bearer pirc_dev_old", get.headers["Authorization"])
        assertEquals("pirc-app/2", get.headers["X-Pirc-Client"])
        assertNull(get.headers["X-Pirc-Request"])

        assertTrue(client.scheduleRun("sc1", "r 1") is BackgroundResult.Done)
        assertEquals("/api/schedules/sc1/runs/r%201", server.takeRequest().url.encodedPath)
    }

    @Test fun sendsAnswersAndScheduleDecisionsWithTheRequestHeader() {
        repeat(3) { enqueue(200, "{}") }
        val client = client()

        client.answer("s1", "i1", JSONObject().put("value", "yes"))
        val answer = server.takeRequest()
        assertEquals("POST", answer.method)
        assertEquals("/api/sessions/s1/interactions/i1/answer", answer.url.encodedPath)
        assertEquals("1", answer.headers["X-Pirc-Request"])
        assertEquals("pirc-app/2", answer.headers["X-Pirc-Client"])
        assertEquals("Bearer pirc_dev_old", answer.headers["Authorization"])
        val body = JSONObject(answer.body!!.utf8())
        assertEquals("client-1", body.getString("clientId"))
        assertEquals("yes", body.getJSONObject("answer").getString("value"))

        client.allowRun("sc1", "r1", commandId = "command-2")
        val allow = server.takeRequest()
        assertEquals("/api/schedules/sc1/run", allow.url.encodedPath)
        assertEquals("""{"runId":"r1"}""", allow.body!!.utf8())
        assertEquals("1", allow.headers["X-Pirc-Request"])

        client.dismissRun("sc1", "r1", commandId = "command-3")
        val dismiss = server.takeRequest()
        assertEquals("/api/schedules/sc1/runs/r1/dismiss", dismiss.url.encodedPath)
        assertEquals("1", dismiss.headers["X-Pirc-Request"])
    }

    @Test fun redirectsAreRefusedNotFollowed() {
        enqueue(302, "", "Location" to server.url("/elsewhere").toString())
        enqueue(200, "{}")

        val result = client().interaction("s1", "i1")

        assertEquals(BackgroundResult.Refused(302, "redirect_refused", "The gateway answered with a redirect; it was not followed."), result)
        assertEquals(1, server.requestCount)
    }

    @Test fun a401WithTheSameStoredTokenIsNotSentAgain() {
        enqueue(401, """{"error":{"code":"unauthenticated","message":"m"}}""")

        val result = client().answer("s1", "i1", JSONObject().put("value", "yes"))

        assertEquals(BackgroundResult.Refused(401, "unauthenticated", "m"), result)
        assertEquals(1, server.requestCount)
    }

    @Test fun a401IsSentOnceMoreWhenTheStoredTokenChanged() {
        server.enqueue(MockResponse.Builder().code(401).build())
        enqueue(200, "{}")
        val client = BackgroundClient(
            gateway = server.url("/"),
            clientId = "client-1",
            // The app rotated the token while the first request was on its way.
            tokens = { token.also { token = "pirc_dev_new" } },
            newCommandId = { "command-1" },
        )

        val result = client.answer("s1", "i1", JSONObject().put("value", "yes"))

        assertTrue(result is BackgroundResult.Done)
        assertEquals(2, server.requestCount)
        assertEquals("Bearer pirc_dev_old", server.takeRequest().headers["Authorization"])
        assertEquals("Bearer pirc_dev_new", server.takeRequest().headers["Authorization"])
    }

    @Test fun a401IsRetriedOnlyOnce() {
        repeat(3) { enqueue(401) }
        var reads = 0
        val client = BackgroundClient(
            gateway = server.url("/"),
            clientId = "client-1",
            tokens = { "pirc_dev_${reads++}" },
        )

        val result = client.interaction("s1", "i1")

        assertEquals(BackgroundResult.Refused(401, null, null), result)
        assertEquals(2, server.requestCount)
    }

    @Test fun a401IsNotRetriedWhenTheTokenWasDeleted() {
        enqueue(401)
        enqueue(200, "{}")
        val client = BackgroundClient(
            gateway = server.url("/"),
            clientId = "client-1",
            tokens = { token.also { token = null } },
        )

        assertEquals(BackgroundResult.Refused(401, null, null), client.dismissRun("sc1", "r1"))
        assertEquals(1, server.requestCount)
    }

    @Test fun noStoredTokenSendsNothing() {
        token = null
        assertEquals(BackgroundResult.Unpaired, client().interaction("s1", "i1"))
        assertEquals(BackgroundResult.Unpaired, client().allowRun("sc1", "r1"))
        assertEquals(0, server.requestCount)
    }

    @Test fun aSendWithAnUnknownOutcomeIsNotSureAndNeverSentAgain() {
        enqueue(200, "{}")
        // The connection drops after the request went out.
        val dropping = GatewayHttp.client().newBuilder()
            .addInterceptor { chain ->
                chain.proceed(chain.request()).close()
                throw IOException("connection reset")
            }
            .build()
        val client = client(dropping)

        val result = client.answer("s1", "i1", JSONObject().put("value", "yes"))

        assertTrue(result is BackgroundResult.NotSure)
        assertEquals("command-1", (result as BackgroundResult.NotSure).commandId)
        assertEquals(setOf("command-1"), client.notSure)
        assertEquals(1, server.requestCount)
        val again = runCatching { client.answer("s1", "i1", JSONObject().put("value", "yes"), commandId = "command-1") }
        assertTrue(again.exceptionOrNull() is IllegalStateException)
        assertEquals(1, server.requestCount)
    }

    @Test fun aProxy5xxIsNotSureButTheGatewaysOwnErrorIsARefusal() {
        enqueue(502, "<html>bad gateway</html>")
        enqueue(409, """{"error":{"code":"stale_interaction","message":"answered"}}""")
        val client = client()

        assertTrue(client.answer("s1", "i1", JSONObject(), commandId = "a") is BackgroundResult.NotSure)
        assertEquals(
            BackgroundResult.Refused(409, "stale_interaction", "answered"),
            client.answer("s1", "i1", JSONObject(), commandId = "b"),
        )
        assertEquals(setOf("a"), client.notSure)
    }

    @Test fun theGatewaysUnknownOutcomeErrorsAreNotSure() {
        enqueue(504, """{"error":{"code":"node_timeout","message":"Node did not answer"}}""")
        enqueue(503, """{"error":{"code":"node_offline","message":"Node connection failed"}}""")
        enqueue(503, """{"error":{"code":"outcome_unknown","message":"m"}}""")
        val client = client()

        assertTrue(client.answer("s1", "i1", JSONObject(), commandId = "a") is BackgroundResult.NotSure)
        assertTrue(client.allowRun("sc1", "r1", commandId = "b") is BackgroundResult.NotSure)
        assertTrue(client.dismissRun("sc1", "r1", commandId = "c") is BackgroundResult.NotSure)
        assertEquals(setOf("a", "b", "c"), client.notSure)
        assertEquals(3, server.requestCount)
    }

    @Test fun aConnectionDroppedAfterTheRequestIsNotSentAgainByOkHttp() {
        // A pooled connection first: OkHttp would retry a stale pooled connection.
        enqueue(200, "{}")
        server.enqueue(MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build())
        enqueue(200, "{}")
        val client = client()
        assertTrue(client.interaction("s1", "i1") is BackgroundResult.Done)

        val result = client.answer("s1", "i1", JSONObject().put("value", "yes"))

        assertTrue(result is BackgroundResult.NotSure)
        assertEquals(2, server.requestCount)
        assertEquals(setOf("command-1"), client.notSure)
    }

    @Test fun aTokenThatCannotBeReadSendsNothing() {
        val client = BackgroundClient(
            gateway = server.url("/"),
            clientId = "client-1",
            tokens = { throw IllegalStateException("Keystore busy") },
        )

        assertTrue(client.answer("s1", "i1", JSONObject(), commandId = "a") is BackgroundResult.Unreachable)
        assertTrue(client.interaction("s1", "i1") is BackgroundResult.Unreachable)
        assertEquals(emptySet<String>(), client.notSure)
        assertEquals(0, server.requestCount)
    }

    @Test fun aFailedReadCanBeReadAgain() {
        val failing = GatewayHttp.client().newBuilder()
            .addInterceptor { throw IOException("offline") }
            .build()
        assertTrue(client(failing).interaction("s1", "i1") is BackgroundResult.Unreachable)
    }

    @Test fun theProxyHookCarriesTheRequests() {
        enqueue(200, "{}")
        val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress(server.hostName, server.port))
        val client = BackgroundClient(
            gateway = "http://gateway.invalid/".toHttpUrl(),
            clientId = "client-1",
            tokens = { token },
            http = GatewayHttp.client { proxy },
        )

        assertTrue(client.interaction("s1", "i1") is BackgroundResult.Done)
        assertEquals("gateway.invalid", server.takeRequest().headers["Host"])
    }
}
