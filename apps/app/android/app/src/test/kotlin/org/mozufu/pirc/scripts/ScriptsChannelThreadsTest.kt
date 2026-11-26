package org.mozufu.pirc.scripts

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mozufu.pirc.direct
import org.robolectric.RobolectricTestRunner

/**
 * Hung requests of one document must not stall the quick calls or other documents
 * (plans/roadmap.md M8 step 6). These tests use real thread pools; requests to `/hang/…`
 * never get an answer until the test ends.
 */
@RunWith(RobolectricTestRunner::class)
class ScriptsChannelThreadsTest {
    /** A result that another thread may answer. */
    private class Pending : MethodChannel.Result {
        private val latch = CountDownLatch(1)
        @Volatile var value: Any? = null
        @Volatile var errorCode: String? = null

        val answered: Boolean get() = latch.count == 0L

        override fun success(result: Any?) {
            value = result
            latch.countDown()
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            this.errorCode = errorCode
            latch.countDown()
        }

        override fun notImplemented() {
            errorCode = "notImplemented"
            latch.countDown()
        }

        fun await(): Pending {
            assertTrue("no answer within 5 s", latch.await(5, TimeUnit.SECONDS))
            return this
        }
    }

    private val release = CountDownLatch(1)
    private val arrived = Semaphore(0)
    private val server = MockWebServer().apply {
        dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.url.encodedPath.startsWith("/hang")) {
                    arrived.release()
                    release.await(30, TimeUnit.SECONDS)
                }
                return MockResponse.Builder().code(200)
                    .addHeader("Access-Control-Allow-Origin", "*")
                    .addHeader("Content-Type", "audio/mpeg")
                    .body("ok").build()
            }
        }
    }
    private val engine = FakeEngine()
    private val scripts = DocumentScripts(engine, resources = ScriptResources(addressPolicy = { true }))
    private val channels = mutableListOf<ScriptsChannel>()

    @Before fun start() = server.start()

    @After fun stop() {
        release.countDown()
        channels.forEach { it.detach() }
        server.close()
    }

    private fun channel(
        network: Executor = ScriptsChannel.boundedExecutor(ScriptsChannel.NETWORK_THREADS),
        control: Executor = ScriptsChannel.boundedExecutor(ScriptsChannel.CONTROL_THREADS),
    ) = ScriptsChannel(scripts, network = network, control = control, reply = direct).also { channels += it }

    private fun ScriptsChannel.send(method: String, args: Map<String, Any?>? = null) =
        Pending().also { onMethodCall(MethodCall(method, args), it) }

    private fun ScriptsChannel.open(owner: String): Int =
        (send("open", mapOf("owner" to owner)).await().value as Map<*, *>)["id"] as Int

    private fun ScriptsChannel.fetch(id: Int, owner: String, requestId: String, path: String) =
        send("resource", mapOf("id" to id, "owner" to owner, "request" to mapOf("id" to requestId, "url" to server.url(path).toString())))

    private fun ScriptsChannel.media(requestId: String, path: String) =
        send("media", mapOf("url" to server.url(path).toString(), "requestId" to requestId))

    private fun awaitArrivals(count: Int) = assertTrue("$count requests did not arrive", arrived.tryAcquire(count, 10, TimeUnit.SECONDS))

    @Test fun everyDocumentAtItsCapStillLeavesNetworkThreads() {
        assertTrue(ScriptsChannel.NETWORK_THREADS > (DocumentScripts.MAX_SESSIONS + 1) * ScriptResources.MAX_IN_FLIGHT)
    }

    @Test fun closeAllAnswersWhileTheNetworkThreadsAreFull() {
        val channel = channel(network = ScriptsChannel.boundedExecutor(2, queued = 4))
        val first = channel.open("doc-1")
        val second = channel.open("doc-2")
        val hung = listOf(channel.fetch(first, "doc-1", "r1", "/hang/1"), channel.fetch(second, "doc-2", "r1", "/hang/2"))
        awaitArrivals(2)
        // Both network threads wait on the network: more requests wait in the queue, then are refused.
        val queued = (1..4).map { channel.fetch(first, "doc-1", "q$it", "/hang/q") }
        assertEquals("SCRIPT_CAPACITY", channel.fetch(first, "doc-1", "over", "/hang/over").await().errorCode)
        // The quick calls do not wait behind them.
        assertEquals(true, (channel.send("capabilities").await().value as Map<*, *>)["supported"])
        assertNull(channel.send("closeAll").await().errorCode)
        assertEquals(0, scripts.openCount)
        assertTrue(engine.isolates.all { it.closed })
        // The old sessions do not live on: their requests are cancelled, and the queued ones
        // find the sessions closed.
        hung.forEach { assertEquals("RESOURCE", it.await().errorCode) }
        queued.forEach { assertEquals("SCRIPT_CLOSED", it.await().errorCode) }
    }

    @Test fun closingIsNeverRefused() {
        val channel = channel(control = Executor { throw RejectedExecutionException() })
        channel.open("doc-1")
        val second = channel.open("doc-2")
        assertEquals("SCRIPT_CAPACITY", channel.send("capabilities").await().errorCode)
        assertNull(channel.send("close", mapOf("id" to second, "owner" to "doc-2")).await().errorCode)
        assertEquals(1, scripts.openCount)
        assertNull(channel.send("closeAll").await().errorCode)
        assertEquals(0, scripts.openCount)
    }

    @Test fun oneDocumentsHungRequestsDoNotHoldUpAnother() {
        val channel = channel()
        val busy = channel.open("busy")
        val other = channel.open("other")
        val hung = (1..ScriptResources.MAX_IN_FLIGHT).map { channel.fetch(busy, "busy", "r$it", "/hang/$it") }
        awaitArrivals(ScriptResources.MAX_IN_FLIGHT)
        // Over its cap, the document is refused at once instead of taking more threads.
        assertEquals("RESOURCE", channel.fetch(busy, "busy", "more", "/hang/more").await().errorCode)
        // Another document still runs its script and loads, and a tapped media element loads.
        val value = channel.send("evaluate", mapOf("id" to other, "owner" to "other", "source" to "1+1")).await().value
        assertEquals(mapOf("value" to "ok:1+1"), value)
        assertNull(channel.fetch(other, "other", "r1", "/ok").await().errorCode)
        val media = channel.media("m1", "/a.mp3").await()
        assertArrayEquals("ok".toByteArray(), (media.value as Map<*, *>)["bytes"] as ByteArray)

        // Two more documents and media, all at their caps, still leave threads for the last one.
        val more = listOf("busy-2", "busy-3").flatMap { owner ->
            val id = channel.open(owner)
            (1..ScriptResources.MAX_IN_FLIGHT).map { channel.fetch(id, owner, "r$it", "/hang/$owner/$it") }
        } + (1..ScriptResources.MAX_IN_FLIGHT).map { channel.media("hung-$it", "/hang/media/$it") }
        awaitArrivals(3 * ScriptResources.MAX_IN_FLIGHT)
        assertNull(channel.fetch(other, "other", "r2", "/ok").await().errorCode)
        assertFalse((hung + more).any { it.answered })

        channel.send("close", mapOf("id" to busy, "owner" to "busy")).await()
        hung.forEach { assertEquals("RESOURCE", it.await().errorCode) }
    }
}
