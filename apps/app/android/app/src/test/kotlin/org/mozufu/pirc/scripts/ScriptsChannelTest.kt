package org.mozufu.pirc.scripts

import java.net.InetAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mozufu.pirc.call
import org.mozufu.pirc.direct
import org.robolectric.RobolectricTestRunner

/** A JavaScript engine for JVM tests: the real sandbox runs only on a device. */
internal class FakeEngine(var unsupported: String? = null, var canvas: Boolean = true) : ScriptEngine {
    val isolates = mutableListOf<FakeIsolate>()
    var closed = false

    override fun unsupportedReason() = unsupported
    override fun canvasTextSupported() = canvas
    override fun createIsolate() = FakeIsolate().also { isolates += it }
    override fun close() {
        closed = true
    }
}

internal class FakeIsolate : ScriptIsolate {
    val evaluated = mutableListOf<String>()
    val data = mutableListOf<Pair<String, ByteArray>>()
    var failWith: ScriptFailure? = null
    var closed = false
    private var terminated: ((Boolean) -> Unit)? = null

    override fun evaluate(source: String, timeoutMillis: Long): String {
        failWith?.let { throw it }
        check(!closed) { "evaluated after close" }
        evaluated += source
        return "ok:$source"
    }

    override fun provideData(name: String, bytes: ByteArray) {
        data += name to bytes
    }

    override fun onTerminated(callback: (Boolean) -> Unit) {
        terminated = callback
    }

    fun terminate(sandboxDead: Boolean) = terminated!!(sandboxDead)

    override fun close() {
        closed = true
    }
}

@RunWith(RobolectricTestRunner::class)
class ScriptsChannelTest {
    private val engine = FakeEngine()
    private val scripts = DocumentScripts(engine, runtimeSource = { "runtime()" })
    private val channel = ScriptsChannel(scripts, work = direct, network = direct, control = direct, reply = direct)

    private fun open(owner: String): Int {
        val answer = channel.call("open", mapOf("owner" to owner))
        assertNull(answer.errorCode)
        val value = answer.value as Map<*, *>
        assertEquals("null", value["origin"])
        return value["id"] as Int
    }

    private fun storage(id: Int, owner: String, vararg operations: Map<String, Any?>): Map<*, *> =
        channel.call("storage", mapOf("id" to id, "owner" to owner, "operations" to operations.toList())).value as Map<*, *>

    private fun cookie(id: Int, owner: String, vararg writes: String): String? =
        (channel.call("cookies", mapOf("id" to id, "owner" to owner, "writes" to writes.toList())).value as Map<*, *>?)
            ?.get("cookie") as String?

    @Test fun eachMessageDocumentHasItsOwnStorage() {
        val first = open("message-a")
        val second = open("message-b")
        storage(first, "message-a", mapOf("area" to "local", "op" to "set", "key" to "k", "value" to "a"))
        storage(first, "message-a", mapOf("area" to "session", "op" to "set", "key" to "s", "value" to "1"))
        assertEquals(mapOf("k" to "a"), storage(first, "message-a")["local"])
        assertEquals(mapOf("s" to "1"), storage(first, "message-a")["session"])
        // Another message sees nothing of it, and cannot name the first one's storage.
        assertEquals(emptyMap<String, String>(), storage(second, "message-b")["local"])
        val foreign = channel.call(
            "storage",
            mapOf("id" to first, "owner" to "message-b", "partition" to "message-a", "operations" to emptyList<Any>()),
        )
        assertEquals("SCRIPT_OWNER", foreign.errorCode)
        // Storage lives only while the document is open.
        channel.call("close", mapOf("id" to first, "owner" to "message-a"))
        val again = open("message-a")
        assertEquals(emptyMap<String, String>(), storage(again, "message-a")["local"])
        assertEquals(emptyMap<String, String>(), storage(again, "message-a")["session"])
    }

    @Test fun storageKeepsItsQuotaAndRefusesUnknownOperations() {
        val id = open("quota")
        val big = "x".repeat((DocumentStorage.QUOTA_CHARS / 2).toInt())
        storage(id, "quota", mapOf("area" to "local", "op" to "set", "key" to "a", "value" to big))
        val full = channel.call("storage", mapOf("id" to id, "owner" to "quota", "operations" to listOf(
            mapOf("area" to "local", "op" to "set", "key" to "b", "value" to big),
            mapOf("area" to "local", "op" to "set", "key" to "c", "value" to "c"),
        )))
        assertEquals("STORAGE_QUOTA", full.errorCode)
        assertEquals(setOf("a"), (storage(id, "quota")["local"] as Map<*, *>).keys)
        val unknown = channel.call("storage", mapOf("id" to id, "owner" to "quota", "operations" to listOf(
            mapOf("area" to "indexedDB", "op" to "set", "key" to "b", "value" to "1"),
        )))
        assertEquals("INVALID", unknown.errorCode)
    }

    @Test fun eachMessageDocumentHasItsOwnCookies() {
        val first = open("cookie-a")
        val second = open("cookie-b")
        assertEquals("theme=dark", cookie(first, "cookie-a", "theme=dark; Path=/; SameSite=Lax"))
        assertEquals("", cookie(second, "cookie-b"))
        // HttpOnly and prefixed cookies need a server or a secure origin; a script gets neither.
        assertEquals("theme=dark", cookie(first, "cookie-a", "session=1; HttpOnly", "__Host-id=1", "__Secure-id=1"))
        assertEquals("theme=dark; n=2", cookie(first, "cookie-a", "n=1", "n=2"))
        assertEquals("theme=dark", cookie(first, "cookie-a", "n=; Max-Age=0"))
        channel.call("close", mapOf("id" to first, "owner" to "cookie-a"))
        assertEquals("", cookie(open("cookie-a"), "cookie-a"))
    }

    @Test fun cookiesExpire() {
        var now = 1_000_000L
        val cookies = DocumentCookies { now }
        cookies.write(listOf("a=1; Max-Age=10", "b=2"))
        assertEquals("a=1; b=2", cookies.read())
        now += 11_000
        assertEquals("b=2", cookies.read())
        cookies.write(listOf("b=3; Expires=Thu, 01 Jan 1970 00:00:00 GMT"))
        assertEquals("", cookies.read())
    }

    @Test fun sessionLifecycle() {
        val ids = (1..DocumentScripts.MAX_SESSIONS).map { open("doc-$it") }
        assertEquals(4, ids.toSet().size)
        assertEquals("SCRIPT_CAPACITY", channel.call("open", mapOf("owner" to "doc-5")).errorCode)
        assertEquals("SCRIPT_OWNER", channel.call("close", mapOf("id" to ids[0], "owner" to "doc-2")).errorCode)
        // The runtime comes from the APK, never from Dart.
        assertNull(channel.call("runtime", mapOf("id" to ids[0], "owner" to "doc-1")).errorCode)
        assertEquals(listOf("runtime()"), engine.isolates[0].evaluated)
        val value = channel.call("evaluate", mapOf("id" to ids[0], "owner" to "doc-1", "source" to "1+1")).value
        assertEquals(mapOf("value" to "ok:1+1"), value)

        // A script that runs too long loses its isolate.
        engine.isolates[1].failWith = ScriptFailure("SCRIPT_TIMEOUT", "slow")
        assertEquals("SCRIPT_TIMEOUT", channel.call("evaluate", mapOf("id" to ids[1], "owner" to "doc-2", "source" to "for(;;){}")).errorCode)
        assertTrue(engine.isolates[1].closed)
        assertEquals("SCRIPT_CLOSED", channel.call("evaluate", mapOf("id" to ids[1], "owner" to "doc-2", "source" to "1")).errorCode)

        // An isolate that ends on its own is retired; a dead sandbox ends every session.
        engine.isolates[2].terminate(sandboxDead = false)
        assertEquals("SCRIPT_CLOSED", channel.call("evaluate", mapOf("id" to ids[2], "owner" to "doc-3", "source" to "1")).errorCode)
        assertEquals(2, scripts.openCount)
        engine.isolates[3].terminate(sandboxDead = true)
        assertEquals(0, scripts.openCount)
        assertTrue(engine.isolates.all { it.closed })

        // Unpairing closes everything; the engine itself closes with the activity.
        open("after")
        assertNull(channel.call("closeAll").errorCode)
        assertEquals(0, scripts.openCount)
        assertTrue(engine.isolates.last().closed)
        channel.detach()
        assertTrue(engine.closed)
        assertEquals("SCRIPT_CLOSED", channel.call("open", mapOf("owner" to "late")).errorCode)
    }

    @Test fun limitsAndBadArguments() {
        val id = open("limits")
        val huge = "x".repeat(DocumentScripts.MAX_VALUE_BYTES + 1)
        assertEquals("SCRIPT_LIMIT", channel.call("evaluate", mapOf("id" to id, "owner" to "limits", "source" to huge)).errorCode)
        assertEquals("SCRIPT_OWNER", channel.call("open", mapOf("owner" to " ")).errorCode)
        assertEquals("INVALID", channel.call("evaluate", mapOf("owner" to "limits", "source" to "1")).errorCode)
        assertTrue(channel.call("unknown").notImplemented)
    }

    @Test fun anUnsupportedEngineOpensNothing() {
        engine.unsupported = "no sandbox"
        assertEquals(mapOf("supported" to false, "reason" to "no sandbox"), channel.call("capabilities").value)
        assertEquals("SCRIPT_UNSUPPORTED", channel.call("open", mapOf("owner" to "x")).errorCode)
        assertTrue(engine.isolates.isEmpty())
    }

    @Test fun canvasFontsGoStraightIntoTheIsolateOncePerFile() {
        val shared = byteArrayOf(1, 2, 3)
        val other = byteArrayOf(4)
        val source = object : CanvasTextSource {
            override fun wasm() = byteArrayOf(9)
            override fun glue() = "glue()"
            override fun collect(families: List<String>, sample: String) = mapOf(
                "resources" to listOf(
                    mapOf("id" to "r0", "bytes" to shared, "ttcIndex" to 0),
                    mapOf("id" to "r1", "bytes" to shared, "ttcIndex" to 1),
                    mapOf("id" to "r2", "bytes" to other, "ttcIndex" to 0),
                ),
                "matches" to listOf(mapOf("family" to "serif", "resourceIds" to listOf("r0"))),
            )
        }
        val canvasScripts = DocumentScripts(engine, canvasText = source)
        val canvasChannel = ScriptsChannel(canvasScripts, work = direct, network = direct, control = direct, reply = direct)
        assertEquals(true, (canvasChannel.call("capabilities").value as Map<*, *>)["canvasText"])
        val id = (canvasChannel.call("open", mapOf("owner" to "canvas")).value as Map<*, *>)["id"]
        val answer = canvasChannel.call("canvasText", mapOf("id" to id, "owner" to "canvas", "families" to listOf("serif"), "sample" to "字"))
        assertNull(answer.errorCode)
        val isolate = engine.isolates.last()
        assertEquals(DocumentScripts.WASM_NAME, isolate.data.first().first)
        assertEquals(setOf("pirc-canvas-font-0", "pirc-canvas-font-1"), isolate.data.drop(1).map { it.first }.toSet())
        assertEquals(3, isolate.data.size)
        assertTrue(isolate.data.single { it.first == "pirc-canvas-font-0" }.second === shared)
        assertEquals(4L, (answer.value as Map<*, *>)["fontBytes"])
        // The set-up runs in the isolate, with names but no font bytes.
        assertEquals("glue()", isolate.evaluated[0])
        val setup = isolate.evaluated[1]
        assertTrue(setup.startsWith("__pircInitializeCanvasText("))
        assertTrue(setup.contains("\"dataName\":\"pirc-canvas-font-1\""))
        assertFalse(setup.contains("bytes\""))
        // Once per document.
        assertEquals("SCRIPT_LIMIT", canvasChannel.call("canvasText", mapOf("id" to id, "owner" to "canvas", "families" to listOf("serif"))).errorCode)
    }

    @Test fun aStuckCanvasSetUpRetiresTheSession() {
        val source = object : CanvasTextSource {
            override fun wasm() = byteArrayOf(9)
            override fun glue() = "glue()"
            override fun collect(families: List<String>, sample: String) =
                mapOf("resources" to emptyList<Any>(), "matches" to emptyList<Any>())
        }
        val canvasChannel = ScriptsChannel(DocumentScripts(engine, canvasText = source), work = direct, network = direct, control = direct, reply = direct)
        val id = (canvasChannel.call("open", mapOf("owner" to "stuck")).value as Map<*, *>)["id"]
        engine.isolates.last().failWith = ScriptFailure("SCRIPT_TIMEOUT", "slow")
        assertEquals("SCRIPT_TIMEOUT", canvasChannel.call("canvasText", mapOf("id" to id, "owner" to "stuck", "families" to listOf("serif"))).errorCode)
        assertTrue(engine.isolates.last().closed)
        assertEquals("SCRIPT_CLOSED", canvasChannel.call("evaluate", mapOf("id" to id, "owner" to "stuck", "source" to "1")).errorCode)
    }

    @Test fun scriptsCannotAskForImages() {
        val id = open("images")
        val answer = channel.call("resource", mapOf("id" to id, "owner" to "images", "request" to mapOf(
            "id" to "image-1", "url" to "https://example.com/a.png", "kind" to "image",
        )))
        assertEquals("RESOURCE", answer.errorCode)
    }

    @Test fun onlyPublicAddressesAreReachable() {
        fun public(address: String) = ScriptResources.isPublicAddress(InetAddress.getByName(address))
        assertTrue(public("8.8.8.8"))
        assertTrue(public("2606:4700:4700::1111"))
        assertTrue(public("64:ff9b::808:808"))
        assertTrue(public("2002:808:808::1"))
        // Teredo is 2001:0::/32 only; the rest of 2001::/16 is ordinary.
        assertTrue(public("2001:4860:4860::8888"))
        // Local-use NAT64 (RFC 8215) in its /96 form carries a public IPv4 address.
        assertTrue(public("64:ff9b:1::808:808"))
        for (address in listOf(
            "127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "100.64.0.1", "100.101.102.103",
            "169.254.1.1", "0.0.0.0", "::1", "fc00::1", "fd7a:115c:a1e0::1", "fe80::1", "::ffff:192.168.1.1",
            "::127.0.0.1", "::10.0.0.1", "64:ff9b::7f00:1", "64:ff9b::a00:1", "2002:c0a8:101::1", "2002:7f00:1::1",
            // RFC 8215: private targets, and forms with the IPv4 address somewhere else.
            "64:ff9b:1::7f00:1", "64:ff9b:1::a00:1", "64:ff9b:1::c0a8:101", "64:ff9b:1:7f00:1::",
            "64:ff9b:1:c0a8:1:100::",
            // Teredo, whatever its server and client.
            "2001::1", "2001:0:4136:e378:8000:63bf:3fff:fdd2", "2001:0:808:808::",
        )) {
            assertFalse(address, public(address))
        }
    }
}
