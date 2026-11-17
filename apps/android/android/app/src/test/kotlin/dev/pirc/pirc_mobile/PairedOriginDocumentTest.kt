package dev.pirc.pirc_mobile

import android.content.Context
import android.content.ContextWrapper
import dev.pirc.android.core.Pairing
import kotlinx.coroutines.runBlocking
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test

/**
 * Runtime boundary for documents served by the paired origin: they are shown as inert content and
 * never get a script execution environment, never act as same-origin script/stylesheet/fetch
 * resources, and never reach the paired origin's cookie or storage scope. A MockWebServer plays the
 * paired origin and records what actually reaches it.
 */
class PairedOriginDocumentTest {
    private val scriptPage = """
        <!doctype html><html><head><title>t</title></head><body>
        <form action="/form" method="post"><input name="a" value="1"><button>go</button></form>
        <script>
          fetch('/api/script-fetch');
          var x = new XMLHttpRequest(); x.open('GET', '/api/script-xhr'); x.send();
          new Image().src = '/api/script-image.png';
        </script></body></html>
    """.trimIndent()

    private fun pairing(server: MockWebServer) =
        Pairing(server.url("/").toString().trimEnd('/'), "device-token")

    private fun origin(server: MockWebServer): String =
        server.url("/").let { "${it.scheme}://${it.host}:${it.port}" }

    /** A script engine whose only real work is the gate; no sandbox exists on the JVM. */
    private fun engine(pairing: Pairing?): NativeDocumentScripts {
        val context = object : ContextWrapper(null) {
            override fun getApplicationContext(): Context = this
        }
        return NativeDocumentScripts(context) { url, creator ->
            PairedOriginPolicy.requireScriptable(pairing, url, creator)
        }
    }

    private fun openCode(engine: NativeDocumentScripts, url: String, blobCreator: String? = null): String? =
        try {
            runBlocking { engine.open("owner", url, null, blobCreator) }
            null
        } catch (error: DocumentScriptException) {
            error.code
        } catch (_: Throwable) {
            "OTHER"
        }

    @Test fun theOriginComparisonIsSchemeHostAndEffectivePort() {
        val pairing = Pairing("https://Gateway.Example.test", "t")
        val paired = pairing.baseUrl.toHttpUrl()
        assertTrue(PairedOriginPolicy.isPairedOrigin(paired, "https://gateway.example.test:443/x?y#z".toHttpUrl()))
        assertFalse(PairedOriginPolicy.isPairedOrigin(paired, "http://gateway.example.test/".toHttpUrl()))
        assertFalse(PairedOriginPolicy.isPairedOrigin(paired, "https://gateway.example.test:8443/".toHttpUrl()))
        assertFalse(PairedOriginPolicy.isPairedOrigin(paired, "https://sub.gateway.example.test/".toHttpUrl()))
        assertFalse(PairedOriginPolicy.isPairedOrigin(paired, "https://gateway.example.test.evil.test/".toHttpUrl()))
        assertFalse(PairedOriginPolicy.isPairedOrigin(null, "https://gateway.example.test/".toHttpUrl()))
        assertTrue(PairedOriginPolicy.isPairedOrigin(pairing, "https://gateway.example.test"))
        assertFalse(PairedOriginPolicy.isPairedOrigin(pairing, "null"))
        assertFalse(PairedOriginPolicy.isPairedOrigin(null, "https://gateway.example.test"))
    }

    @Test fun noScriptSessionIsCreatedForAPairedOriginDocumentAndOthersAreNotRefusedByTheGate() {
        val pairing = Pairing("https://gateway.example.test", "t")
        val engine = engine(pairing)
        for (url in listOf(
            "https://gateway.example.test/",
            "https://gateway.example.test:443/files/a.html?x=1#f",
            "https://GATEWAY.example.test/%2e%2e/a.html",
        )) {
            assertEquals(url, PairedOriginPolicy.ERROR_CODE, openCode(engine, url))
        }
        // A blob document keeps its creator's origin; a blob created on the paired origin is refused too.
        assertEquals(
            PairedOriginPolicy.ERROR_CODE,
            openCode(engine, "blob:https://gateway.example.test/1111", "https://gateway.example.test/a"),
        )
        // Other origins pass the gate; the JVM has no sandbox, so what follows is not the gate.
        for (url in listOf("https://elsewhere.example.test/", "https://gateway.example.test:8443/")) {
            val code = openCode(engine, url)
            assertNotEquals(url, PairedOriginPolicy.ERROR_CODE, code)
        }
    }

    @Test fun aPairedOriginResponseIsFlaggedInertAndItsScriptsReachNoServer() {
        for (contentType in listOf("text/html", "text/html; charset=utf-8")) {
            MockWebServer().use { gateway ->
                gateway.dispatcher = object : Dispatcher() {
                    override fun dispatch(request: RecordedRequest): MockResponse =
                        MockResponse.Builder().addHeader("Content-Type", contentType).body(scriptPage).build()
                }
                gateway.start()
                val pairing = pairing(gateway)
                val response = NativeDocumentTransport(pairing).load(gateway.url("/page.html").toString(), "GET", null, null)
                assertEquals(true, response["pairedOrigin"])
                assertEquals(gateway.url("/page.html").toString(), response["finalUrl"])
                assertEquals(1, gateway.requestCount)
                assertNull(gateway.takeRequest().headers["Authorization"])

                // The engine refuses to create the execution environment for that final URL...
                assertEquals(contentType, PairedOriginPolicy.ERROR_CODE, openCode(engine(pairing), response["finalUrl"] as String))
                // ...and everything a script of that document could try is refused before the network.
                val transport = NativeScriptResourceTransport(pairing)
                val kinds = listOf(
                    "/api/script-fetch" to NativeScriptResourceTransport.Kind.FETCH,
                    "/api/script-image.png" to NativeScriptResourceTransport.Kind.IMAGE,
                    "/style.css" to NativeScriptResourceTransport.Kind.STYLESHEET,
                    "/main.js" to NativeScriptResourceTransport.Kind.CLASSIC_SCRIPT,
                    "/mod.js" to NativeScriptResourceTransport.Kind.MODULE_SCRIPT,
                )
                for ((path, kind) in kinds) {
                    assertThrows(path, IllegalArgumentException::class.java) {
                        transport.load(
                            origin(gateway),
                            NativeScriptResourceTransport.ResourceRequest(gateway.url(path).toString(), kind = kind),
                            baseUrl = gateway.url("/page.html").toString(),
                            initiatorUrl = gateway.url("/page.html").toString(),
                            topLevelUrl = gateway.url("/page.html").toString(),
                        )
                    }
                }
                assertEquals("the receiving server saw only the document request", 1, gateway.requestCount)
            }
        }
    }

    @Test fun anExternalPageThatRedirectsToThePairedOriginIsInertAndOneRedirectedAwayIsNot() {
        MockWebServer().use { gateway -> MockWebServer().use { external ->
            gateway.start(); external.start()
            val pairing = pairing(gateway)

            // external -> 302 -> paired: the final URL decides, not the one that was requested.
            external.enqueue(MockResponse.Builder().code(302).addHeader("Location", gateway.url("/landing.html").toString()).build())
            gateway.enqueue(MockResponse.Builder().addHeader("Content-Type", "text/html").body(scriptPage).build())
            val inbound = NativeDocumentTransport(pairing).load(external.url("/go").toString(), "GET", null, null)
            assertEquals(gateway.url("/landing.html").toString(), inbound["finalUrl"])
            assertEquals(true, inbound["pairedOrigin"])
            assertEquals(PairedOriginPolicy.ERROR_CODE, openCode(engine(pairing), inbound["finalUrl"] as String))
            val landed = gateway.takeRequest()
            assertNull(landed.headers["Authorization"])
            assertEquals("only the document load reached the paired origin", 1, gateway.requestCount)

            // paired -> 302 -> external: the document lives on the external origin and keeps working.
            gateway.enqueue(MockResponse.Builder().code(302).addHeader("Location", external.url("/away.html").toString()).build())
            external.enqueue(MockResponse.Builder().addHeader("Content-Type", "text/html; charset=utf-8").body(scriptPage).build())
            val outbound = NativeDocumentTransport(pairing).load(gateway.url("/out").toString(), "GET", null, null)
            assertEquals(external.url("/away.html").toString(), outbound["finalUrl"])
            assertEquals(false, outbound["pairedOrigin"])
            assertNotEquals(PairedOriginPolicy.ERROR_CODE, openCode(engine(pairing), outbound["finalUrl"] as String))
            assertNull(gateway.takeRequest().headers["Authorization"])
            // Its scripts load resources as the external origin does today.
            external.enqueue(MockResponse.Builder().addHeader("Content-Type", "text/plain").body("ok").build())
            val fetched = NativeScriptResourceTransport(pairing).load(
                origin(external),
                NativeScriptResourceTransport.ResourceRequest(external.url("/api/script-fetch").toString()),
                baseUrl = external.url("/away.html").toString(),
            )
            assertEquals(200, fetched.status)
        } }
    }

    @Test fun inertContentFromThePairedOriginStillLoadsForPreviewsDownloadsAndImages() {
        MockWebServer().use { gateway ->
            gateway.start()
            val pairing = pairing(gateway)
            val png = byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47)
            gateway.enqueue(MockResponse.Builder().addHeader("Content-Type", "text/plain").body("preview text").build())
            gateway.enqueue(MockResponse.Builder().addHeader("Content-Type", "application/octet-stream")
                .addHeader("Content-Disposition", "attachment; filename=\"a.bin\"").body("bytes").build())
            gateway.enqueue(MockResponse.Builder().addHeader("Content-Type", "image/png")
                .body(okio.Buffer().write(png)).build())
            val preview = NativeDocumentTransport(pairing).load(gateway.url("/f.txt").toString(), "GET", null, null)
            assertEquals("preview text", String(preview["bytes"] as ByteArray))
            val download = NativeDocumentTransport(pairing).load(gateway.url("/d").toString(), "GET", null, null)
            assertEquals("bytes", String(download["bytes"] as ByteArray))
            assertTrue((download["headersRelevant"] as Map<*, *>)["Content-Disposition"].toString().startsWith("attachment"))
            val image = NativeImageTransport(pairing).load(gateway.url("/i.png").toString(), null)
            assertArrayEquals(png, image["bytes"] as ByteArray)
            // None of them carried the credential: they are content requests.
            repeat(3) { assertNull(gateway.takeRequest().headers["Authorization"]) }
        }
    }

    @Test fun anAppInitiatedRequestIsNotAffectedByTheGuardOnContentResources() {
        MockWebServer().use { gateway ->
            gateway.start()
            val pairing = pairing(gateway)
            gateway.enqueue(MockResponse.Builder().addHeader("Content-Type", "application/json").body("{}").build())
            val response = NativeScriptResourceTransport(pairing, initiator = AppRequestAuthority().issue(pairing)).load(
                origin(gateway),
                NativeScriptResourceTransport.ResourceRequest(gateway.url("/api/x").toString(),
                    mode = NativeScriptResourceTransport.Mode.SAME_ORIGIN),
            )
            assertEquals(200, response.status)
            assertEquals("Bearer device-token", gateway.takeRequest().headers["Authorization"])
        }
    }

    @Test fun nothingOnTheBridgeCanSkipTheGateAndTheGateIsAskedBeforeTheSandbox() {
        val root = listOf(java.io.File("src/main/kotlin/dev/pirc/pirc_mobile"), java.io.File("app/src/main/kotlin/dev/pirc/pirc_mobile"))
            .first { it.isDirectory }
        val scripts = java.io.File(root, "NativeDocumentScripts.kt").readText()
        // The gate runs on the URL the engine derives its own origin from, before it touches the sandbox.
        val open = scripts.substring(scripts.indexOf("suspend fun open("), scripts.indexOf("/** Only packaged engine bytes"))
        val gate = open.indexOf("documentGate(documentUrl, blobCreatorUrl)")
        assertTrue(gate > open.indexOf("originForDocument(documentUrl, blobCreatorUrl)"))
        assertTrue(gate < open.indexOf("requireSupportedSandbox()"))
        // The bridge neither names the exemption nor passes one: it forwards the URL to the runtime.
        val bridge = java.io.File(root, "GatewayBridge.kt").readText()
        assertTrue("runtime.requireScriptableDocument(url, blobCreator)" in bridge)
        assertFalse("pairedOrigin" in bridge)
    }
}
