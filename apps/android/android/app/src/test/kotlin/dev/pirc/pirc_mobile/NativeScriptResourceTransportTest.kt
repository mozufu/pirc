package dev.pirc.pirc_mobile

import dev.pirc.android.core.Pairing
import java.net.InetAddress
import java.security.MessageDigest
import java.util.Base64
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.Dns
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import org.junit.Assert.*
import org.junit.Test

class NativeScriptResourceTransportTest {
    @Test fun moduleDefaultsToCorsAndCannotBeDowngradedByMode() {
        MockWebServer().use { server ->
            server.start()
            val transport = NativeScriptResourceTransport(null)
            for (mode in NativeScriptResourceTransport.Mode.entries) {
                server.enqueue(MockResponse.Builder().addHeader("Content-Type", "text/javascript")
                    .body("export const value = 1").build())
                assertThrows(IllegalStateException::class.java) {
                    transport.load("https://document.example", NativeScriptResourceTransport.ResourceRequest(
                        server.url("/module.js").toString(), kind = NativeScriptResourceTransport.Kind.MODULE_SCRIPT,
                        mode = mode))
                }
                assertEquals("https://document.example", server.takeRequest().headers["Origin"])
            }
        }
    }

    @Test fun moduleWithCorsPermissionKeepsFinalUrlAndVerifiesSri() {
        MockWebServer().use { server ->
            server.start()
            val source = "export const text = '猫'"
            server.enqueue(MockResponse.Builder().code(302).addHeader("Location", "/folder/main.js")
                .addHeader("Access-Control-Allow-Origin", "*").build())
            server.enqueue(MockResponse.Builder().addHeader("Content-Type", "text/javascript; charset=windows-1252")
                .addHeader("Access-Control-Allow-Origin", "*")
                .addHeader("Referrer-Policy", "origin, invalid, no-referrer").body(source).build())
            val response = NativeScriptResourceTransport(null).load("https://document.example",
                NativeScriptResourceTransport.ResourceRequest(server.url("/entry.js").toString(),
                    kind = NativeScriptResourceTransport.Kind.MODULE_SCRIPT,
                    integrity = sri("sha256", source.toByteArray(Charsets.UTF_8))))
            assertEquals(server.url("/folder/main.js").toString(), response.url)
            assertEquals("script", response.type)
            assertEquals("no-referrer", response.moduleReferrerPolicy)
            assertTrue(response.redirected)
            assertArrayEquals(source.toByteArray(Charsets.UTF_8), response.body)
            repeat(2) { assertNull(server.takeRequest().headers["Authorization"]) }
        }
    }

    @Test fun modulesRejectWrongMimeFailedStatusAndMismatchedIntegrity() {
        MockWebServer().use { server ->
            server.start()
            for ((mime, status, integrity) in listOf(Triple("text/html", 200, null),
                    Triple("text/javascript", 404, null), Triple("text/javascript", 200, sri("sha256", byteArrayOf(1))))) {
                server.enqueue(MockResponse.Builder().code(status).addHeader("Content-Type", mime)
                    .body("export const x = 1").build())
                assertThrows(IllegalArgumentException::class.java) {
                    NativeScriptResourceTransport(null).load(origin(server.url("/")),
                        NativeScriptResourceTransport.ResourceRequest(server.url("/module.js").toString(),
                            kind = NativeScriptResourceTransport.Kind.MODULE_SCRIPT, integrity = integrity))
                }
            }
        }
    }

    @Test fun credentialedModulesRequireExplicitCorsPermission() {
        MockWebServer().use { server ->
            server.start()
            for (allowedOrigin in listOf("*", "https://document.example")) {
                server.enqueue(MockResponse.Builder().addHeader("Content-Type", "text/javascript")
                    .addHeader("Access-Control-Allow-Origin", allowedOrigin)
                    .addHeader("Access-Control-Allow-Credentials", "true").body("export {}").build())
                val request = NativeScriptResourceTransport.ResourceRequest(server.url("/module.js").toString(),
                    kind = NativeScriptResourceTransport.Kind.MODULE_SCRIPT, crossOrigin = "use-credentials")
                if (allowedOrigin == "*") assertThrows(IllegalStateException::class.java) {
                    NativeScriptResourceTransport(null).load("https://document.example", request)
                } else assertEquals("script", NativeScriptResourceTransport(null).load("https://document.example", request).type)
            }
        }
    }

    @Test fun documentOriginPreservesIpv6HostBracketsAndRemovesPath() {
        assertEquals(
            "http://[::1]:8080",
            NativeScriptResourceTransport.originForDocument("http://[::1]:8080/path?q=1#fragment"),
        )
    }

    @Test fun blobDocumentInheritsOnlyItsVerifiedHttpCreatorOrigin() {
        val blobUrl = "blob:https://docs.example:443/object/nonce/id"
        assertEquals(
            "https://docs.example",
            NativeScriptResourceTransport.originForDocument(
                blobUrl,
                "https://docs.example/manual/page?source=1",
            ),
        )
        assertEquals(
            "https://docs.example",
            NativeScriptResourceTransport.originForDocument(
                blobUrl,
                "blob:https://docs.example/creator/nonce/id",
            ),
        )

        assertThrows(IllegalArgumentException::class.java) {
            NativeScriptResourceTransport.originForDocument(blobUrl)
        }
        assertThrows(IllegalArgumentException::class.java) {
            NativeScriptResourceTransport.originForDocument(blobUrl, "https://other.example/page")
        }
        assertThrows(IllegalArgumentException::class.java) {
            NativeScriptResourceTransport.originForDocument(
                blobUrl,
                "blob:https://other.example/creator/id",
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            NativeScriptResourceTransport.originForDocument(
                "https://docs.example/page",
                "https://docs.example/creator",
            )
        }

        val forbidden = listOf(
            "blob:null/id" to "https://docs.example/page",
            "blob:https://docs.example" to "https://docs.example/page",
            "blob:file:///tmp/object" to "https://docs.example/page",
            "blob:blob:https://docs.example/inner/id" to "https://docs.example/page",
            "blob:https://user:secret@docs.example/id" to "https://docs.example/page",
            blobUrl to "file:///tmp/creator",
            blobUrl to "blob:null/id",
            blobUrl to "blob:blob:https://docs.example/inner/id",
            blobUrl to "https://user:secret@docs.example/creator",
        )
        forbidden.forEach { (document, creator) ->
            assertThrows(IllegalArgumentException::class.java) {
                NativeScriptResourceTransport.originForDocument(document, creator)
            }
        }
    }

    @Test fun blobDocumentCreatorOriginKeepsPairingCredentialsSameOriginScoped() {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse.Builder().body("ok").build())
            val creatorUrl = server.url("/creator/page").toString()
            val blobUrl = "blob:${server.url("/object/nonce/id")}"
            val source = NativeScriptResourceTransport.originForDocument(blobUrl, creatorUrl)

            val response = NativeScriptResourceTransport(pairing(server), initiator = appInitiated(pairing(server))).load(
                source,
                NativeScriptResourceTransport.ResourceRequest(
                    url = server.url("/resource").toString(),
                    method = "POST",
                    body = "payload".toByteArray(),
                ),
            )

            val request = server.takeRequest()
            assertEquals(origin(server.url("/")), source)
            assertEquals(source, request.headers["Origin"])
            assertEquals("Bearer device-token", request.headers["Authorization"])
            assertArrayEquals("ok".toByteArray(), response.body!!)
        }
    }

    @Test fun pairedDocumentRedirectToAnotherOriginDropsPairingAuthorization() {
        MockWebServer().use { gateway ->
            MockWebServer().use { external ->
                gateway.start()
                external.start()
                gateway.enqueue(
                    MockResponse.Builder()
                        .code(302)
                        .addHeader("Location", external.url("/script.js").toString())
                        .build(),
                )
                external.enqueue(
                    MockResponse.Builder()
                        .addHeader("Access-Control-Allow-Origin", origin(gateway.url("/document")))
                        .addHeader("Content-Type", "text/javascript; charset=utf-8")
                        .body("{\"loaded\":true}")
                        .build(),
                )

                val result = NativeScriptResourceTransport(pairing(gateway), initiator = appInitiated(pairing(gateway))).load(
                    sourceOrigin = origin(gateway.url("/document")),
                    request = NativeScriptResourceTransport.ResourceRequest(
                        url = gateway.url("/redirect").toString(),
                        mode = NativeScriptResourceTransport.Mode.CORS,
                    ),
                )

                val first = gateway.takeRequest()
                val second = external.takeRequest()
                assertEquals("Bearer device-token", first.headers["Authorization"])
                assertNull(second.headers["Authorization"])
                assertEquals(origin(gateway.url("/document")), second.headers["Origin"])
                assertEquals("cors", result.type)
                assertArrayEquals("{\"loaded\":true}".toByteArray(), result.body)
                assertTrue(result.redirected)
            }
        }
    }

    @Test fun crossOriginRedirectBackToSourceStaysCorsTaintedAndKeepsBearerStripped() {
        MockWebServer().use { gateway ->
            MockWebServer().use { external ->
                gateway.start()
                external.start()
                val source = origin(gateway.url("/document"))
                gateway.enqueue(
                    MockResponse.Builder()
                        .code(302)
                        .addHeader("Location", external.url("/bounce").toString())
                        .build(),
                )
                external.enqueue(
                    MockResponse.Builder()
                        .code(302)
                        .addHeader("Access-Control-Allow-Origin", source)
                        .addHeader("Location", gateway.url("/final").toString())
                        .build(),
                )
                gateway.enqueue(
                    MockResponse.Builder()
                        .addHeader("Access-Control-Allow-Origin", "null")
                        .addHeader("X-Private", "hidden after redirect")
                        .body("final")
                        .build(),
                )

                val result = NativeScriptResourceTransport(pairing(gateway), initiator = appInitiated(pairing(gateway))).load(
                    source,
                    NativeScriptResourceTransport.ResourceRequest(
                        url = gateway.url("/start").toString(),
                        mode = NativeScriptResourceTransport.Mode.CORS,
                    ),
                )
                val first = gateway.takeRequest()
                val second = external.takeRequest()
                val third = gateway.takeRequest()
                assertEquals("Bearer device-token", first.headers["Authorization"])
                assertNull(second.headers["Authorization"])
                assertEquals(source, second.headers["Origin"])
                assertNull(third.headers["Authorization"])
                assertEquals("null", third.headers["Origin"])
                assertEquals("cors", result.type)
                assertFalse(result.headers.keys.any { it.equals("X-Private", true) })
                assertArrayEquals("final".toByteArray(), result.body)
            }
        }
    }

    @Test fun redirectBackToSourceStillPreflightsUnsafeCorsRequestWithNullOrigin() {
        MockWebServer().use { sourceServer ->
            MockWebServer().use { externalServer ->
                sourceServer.start()
                externalServer.start()
                val source = origin(sourceServer.url("/document"))
                sourceServer.enqueue(
                    MockResponse.Builder()
                        .code(302)
                        .addHeader("Location", externalServer.url("/bounce").toString())
                        .build(),
                )
                sourceServer.enqueue(
                    MockResponse.Builder()
                        .addHeader("Access-Control-Allow-Origin", "null")
                        .addHeader("Access-Control-Allow-Methods", "PATCH")
                        .addHeader("Access-Control-Allow-Headers", "x-trace")
                        .build(),
                )
                sourceServer.enqueue(
                    MockResponse.Builder()
                        .addHeader("Access-Control-Allow-Origin", "null")
                        .body("done")
                        .build(),
                )
                externalServer.enqueue(
                    MockResponse.Builder()
                        .addHeader("Access-Control-Allow-Origin", source)
                        .addHeader("Access-Control-Allow-Methods", "PATCH")
                        .addHeader("Access-Control-Allow-Headers", "x-trace")
                        .build(),
                )
                externalServer.enqueue(
                    MockResponse.Builder()
                        .code(302)
                        .addHeader("Access-Control-Allow-Origin", source)
                        .addHeader("Location", sourceServer.url("/final").toString())
                        .build(),
                )

                val result = NativeScriptResourceTransport(null).load(
                    source,
                    NativeScriptResourceTransport.ResourceRequest(
                        url = sourceServer.url("/start").toString(),
                        method = "PATCH",
                        headers = listOf(NativeScriptResourceTransport.Header("X-Trace", "123")),
                    ),
                )

                val initial = sourceServer.takeRequest()
                assertEquals("PATCH", initial.method)
                assertEquals("123", initial.headers["X-Trace"])
                val firstExternalPreflight = externalServer.takeRequest()
                assertEquals("OPTIONS", firstExternalPreflight.method)
                assertEquals(source, firstExternalPreflight.headers["Origin"])
                val externalActual = externalServer.takeRequest()
                assertEquals("PATCH", externalActual.method)
                assertEquals(source, externalActual.headers["Origin"])
                val returnPreflight = sourceServer.takeRequest()
                assertEquals("OPTIONS", returnPreflight.method)
                assertEquals("null", returnPreflight.headers["Origin"])
                assertEquals("PATCH", returnPreflight.headers["Access-Control-Request-Method"])
                assertEquals("x-trace", returnPreflight.headers["Access-Control-Request-Headers"])
                val finalRequest = sourceServer.takeRequest()
                assertEquals("PATCH", finalRequest.method)
                assertEquals("null", finalRequest.headers["Origin"])
                assertEquals("done", String(result.body!!))
                assertEquals("cors", result.type)
            }
        }
    }

    @Test fun externalDocumentNeverGetsPairingBearerForPairingOrigin() {
        MockWebServer().use { gateway ->
            MockWebServer().use { external ->
                gateway.start()
                external.start()
                gateway.enqueue(
                    MockResponse.Builder()
                        .addHeader("Access-Control-Allow-Origin", origin(external.url("/document")))
                        .body("gateway data")
                        .build(),
                )

                val result = NativeScriptResourceTransport(pairing(gateway)).load(
                    sourceOrigin = origin(external.url("/document")),
                    request = NativeScriptResourceTransport.ResourceRequest(
                        url = gateway.url("/public").toString(),
                    ),
                )

                val request = gateway.takeRequest()
                assertNull(request.headers["Authorization"])
                assertEquals(origin(external.url("/document")), request.headers["Origin"])
                assertEquals("cors", result.type)
                assertArrayEquals("gateway data".toByteArray(), result.body)
            }
        }
    }

    @Test fun crossOriginNoCorsImageReturnsBytesButIsTaintedAndHidesHeaders() {
        MockWebServer().use { gateway ->
            MockWebServer().use { external ->
                gateway.start()
                external.start()
                val imageBytes = "fixture image bytes".toByteArray()
                gateway.enqueue(
                    MockResponse.Builder()
                        .code(302)
                        .addHeader("Location", external.url("/image.png").toString())
                        .build(),
                )
                external.enqueue(
                    MockResponse.Builder()
                        .addHeader("Content-Type", "image/png")
                        .addHeader("X-Private", "not image-visible")
                        .body(String(imageBytes, Charsets.UTF_8))
                        .build(),
                )

                val source = origin(gateway.url("/document"))
                val result = NativeScriptResourceTransport(pairing(gateway), initiator = appInitiated(pairing(gateway))).load(
                    source,
                    NativeScriptResourceTransport.ResourceRequest(
                        url = gateway.url("/redirect-image").toString(),
                        kind = NativeScriptResourceTransport.Kind.IMAGE,
                    ),
                )

                val initial = gateway.takeRequest()
                val final = external.takeRequest()
                assertEquals("Bearer device-token", initial.headers["Authorization"])
                assertNull(final.headers["Authorization"])
                assertEquals("image", result.type)
                assertFalse(result.originClean)
                assertArrayEquals(imageBytes, result.body!!)
                assertTrue(result.redirected)
                assertTrue(result.headers.isEmpty())
            }
        }
    }

    @Test fun anonymousCorsImageRequiresCorsAndCanPassWithWildcardOrigin() {
        MockWebServer().use { server ->
            server.start()
            val imageBytes = "anonymous image".toByteArray()
            server.enqueue(
                MockResponse.Builder()
                    .addHeader("Content-Type", "image/png")
                    .body(String(imageBytes, Charsets.UTF_8))
                    .build(),
            )
            server.enqueue(
                MockResponse.Builder()
                    .addHeader("Access-Control-Allow-Origin", "*")
                    .addHeader("Content-Type", "image/png")
                    .addHeader("X-Private", "not exposed")
                    .body(String(imageBytes, Charsets.UTF_8))
                    .build(),
            )
            val source = "https://document.example"
            val transport = NativeScriptResourceTransport(null)
            val request = NativeScriptResourceTransport.ResourceRequest(
                url = server.url("/image.png").toString(),
                kind = NativeScriptResourceTransport.Kind.IMAGE,
                crossOrigin = "anonymous",
            )

            assertThrows(IllegalStateException::class.java) {
                transport.load(source, request)
            }
            val failedRequest = server.takeRequest()
            assertEquals(source, failedRequest.headers["Origin"])
            assertEquals(1, server.requestCount)

            val result = transport.load(source, request)
            val successfulRequest = server.takeRequest()
            assertEquals(source, successfulRequest.headers["Origin"])
            assertNull(successfulRequest.headers["Authorization"])
            assertEquals("image", result.type)
            assertTrue(result.originClean)
            assertArrayEquals(imageBytes, result.body!!)
            assertFalse(result.headers.keys.any { it.equals("X-Private", ignoreCase = true) })
        }
    }

    @Test fun sameOriginImageKeepsPairingBearerAndRemainsOriginClean() {
        MockWebServer().use { server ->
            server.start()
            val imageBytes = "same-origin image".toByteArray()
            server.enqueue(
                MockResponse.Builder()
                    .addHeader("Content-Type", "image/png")
                    .body(String(imageBytes, Charsets.UTF_8))
                    .build(),
            )
            val source = origin(server.url("/document"))

            val result = NativeScriptResourceTransport(pairing(server), initiator = appInitiated(pairing(server))).load(
                source,
                NativeScriptResourceTransport.ResourceRequest(
                    url = server.url("/image.png").toString(),
                    kind = NativeScriptResourceTransport.Kind.IMAGE,
                ),
            )

            val request = server.takeRequest()
            assertEquals("Bearer device-token", request.headers["Authorization"])
            assertEquals("image", result.type)
            assertTrue(result.originClean)
            assertArrayEquals(imageBytes, result.body!!)
        }
    }

    @Test fun imageRequestsRejectPostBodyCustomHeadersManualRedirectAndInvalidCrossOrigin() {
        MockWebServer().use { server ->
            server.start()
            val transport = NativeScriptResourceTransport(null)
            val source = origin(server.url("/document"))
            val url = server.url("/image.png").toString()
            val imageKind = NativeScriptResourceTransport.Kind.IMAGE
            val invalidRequests = listOf(
                NativeScriptResourceTransport.ResourceRequest(
                    url = url,
                    method = "POST",
                    kind = imageKind,
                ),
                NativeScriptResourceTransport.ResourceRequest(
                    url = url,
                    body = byteArrayOf(1),
                    kind = imageKind,
                ),
                NativeScriptResourceTransport.ResourceRequest(
                    url = url,
                    headers = listOf(NativeScriptResourceTransport.Header("X-Trace", "123")),
                    kind = imageKind,
                ),
                NativeScriptResourceTransport.ResourceRequest(
                    url = url,
                    redirect = NativeScriptResourceTransport.Redirect.MANUAL,
                    kind = imageKind,
                ),
                NativeScriptResourceTransport.ResourceRequest(
                    url = url,
                    crossOrigin = "use-credential",
                    kind = imageKind,
                ),
            )

            invalidRequests.forEach { request ->
                assertThrows(IllegalArgumentException::class.java) {
                    transport.load(source, request)
                }
            }
            assertEquals(0, server.requestCount)
        }
    }

    @Test fun sameOriginUnsafeMethodsSendOriginAndOnlyPairingCredentialsWhenAllowed() {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse.Builder().body("ok").build())
            server.enqueue(MockResponse.Builder().body("ok").build())
            val transport = NativeScriptResourceTransport(pairing(server), initiator = appInitiated(pairing(server)))
            val source = origin(server.url("/document"))

            transport.load(
                source,
                NativeScriptResourceTransport.ResourceRequest(
                    url = server.url("/post").toString(),
                    method = "POST",
                    body = "payload".toByteArray(),
                ),
            )
            val pairedPost = server.takeRequest()
            assertEquals(source, pairedPost.headers["Origin"])
            assertEquals("Bearer device-token", pairedPost.headers["Authorization"])

            transport.load(
                source,
                NativeScriptResourceTransport.ResourceRequest(
                    url = server.url("/post-without-credentials").toString(),
                    method = "POST",
                    body = "payload".toByteArray(),
                    credentials = NativeScriptResourceTransport.Credentials.OMIT,
                ),
            )
            val omittedPost = server.takeRequest()
            assertEquals(source, omittedPost.headers["Origin"])
            assertNull(omittedPost.headers["Authorization"])
        }
    }

    @Test fun corsManualRedirectChecksCrossOriginRedirectCorsBeforeOpaqueReturn() {
        MockWebServer().use { server ->
            server.start()
            val source = "https://document.example"
            server.enqueue(
                MockResponse.Builder()
                    .code(302)
                    .addHeader("Location", server.url("/target").toString())
                    .build(),
            )
            server.enqueue(
                MockResponse.Builder()
                    .code(302)
                    .addHeader("Access-Control-Allow-Origin", source)
                    .addHeader("Location", server.url("/target").toString())
                    .build(),
            )

            try {
                NativeScriptResourceTransport(null).load(
                    source,
                    NativeScriptResourceTransport.ResourceRequest(
                        url = server.url("/missing-cors").toString(),
                        mode = NativeScriptResourceTransport.Mode.CORS,
                        redirect = NativeScriptResourceTransport.Redirect.MANUAL,
                    ),
                )
                fail("Manual cross-origin redirect without ACAO must fail CORS")
            } catch (e: IllegalStateException) {
                assertTrue(e.message.orEmpty().contains("CORS"))
            }
            assertEquals(source, server.takeRequest().headers["Origin"])

            val opaqueRedirect = NativeScriptResourceTransport(null).load(
                source,
                NativeScriptResourceTransport.ResourceRequest(
                    url = server.url("/with-cors").toString(),
                    mode = NativeScriptResourceTransport.Mode.CORS,
                    redirect = NativeScriptResourceTransport.Redirect.MANUAL,
                ),
            )
            assertEquals("opaqueredirect", opaqueRedirect.type)
            assertEquals(0, opaqueRedirect.status)
            assertNull(opaqueRedirect.body)
            assertEquals(source, server.takeRequest().headers["Origin"])
        }
    }

    @Test fun xhrUploadListenerForcesPreflightForSimpleCrossOriginPost() {
        MockWebServer().use { server ->
            server.start()
            val source = "https://document.example"
            server.enqueue(MockResponse.Builder().code(204)
                .addHeader("Access-Control-Allow-Origin", source).build())
            server.enqueue(MockResponse.Builder().addHeader("Access-Control-Allow-Origin", source)
                .body("received").build())
            val response = NativeScriptResourceTransport(null).load(source,
                NativeScriptResourceTransport.ResourceRequest(url = server.url("/upload").toString(),
                    method = "POST", body = "plain body".toByteArray(),
                    headers = listOf(NativeScriptResourceTransport.Header("Content-Type", "text/plain;charset=UTF-8")),
                    forcePreflight = true))
            val options = server.takeRequest()
            assertEquals("OPTIONS", options.method)
            assertEquals("POST", options.headers["Access-Control-Request-Method"])
            assertNull(options.headers["Access-Control-Request-Headers"])
            assertNull(options.headers["Authorization"])
            val post = server.takeRequest()
            assertEquals("POST", post.method)
            assertEquals("plain body", post.body!!.utf8())
            assertEquals(200, response.status)
        }
    }

    @Test fun deniedForcedPreflightNeverSendsUploadBody() {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse.Builder().code(204).build())
            assertThrows(IllegalStateException::class.java) {
                NativeScriptResourceTransport(null).load("https://document.example",
                    NativeScriptResourceTransport.ResourceRequest(url = server.url("/denied").toString(),
                        method = "POST", body = "must not send".toByteArray(), forcePreflight = true))
            }
            assertEquals("OPTIONS", server.takeRequest().method)
            assertEquals(1, server.requestCount)
        }
    }

    @Test fun forcedPreflightKeepsSameOriginDirectAndRejectsNonCorsKinds() {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse.Builder().body("ok").build())
            val transport = NativeScriptResourceTransport(pairing(server), initiator = appInitiated(pairing(server)))
            val source = origin(server.url("/document"))
            val request = NativeScriptResourceTransport.ResourceRequest(url = server.url("/upload").toString(),
                method = "POST", body = "body".toByteArray(), forcePreflight = true)
            transport.load(source, request)
            val actual = server.takeRequest()
            assertEquals("POST", actual.method)
            assertEquals("Bearer device-token", actual.headers["Authorization"])
            assertThrows(IllegalArgumentException::class.java) {
                transport.load(source, request.copy(mode = NativeScriptResourceTransport.Mode.NO_CORS))
            }
            assertThrows(IllegalArgumentException::class.java) {
                transport.load(source, request.copy(kind = NativeScriptResourceTransport.Kind.CLASSIC_SCRIPT))
            }
            assertEquals(1, server.requestCount)
        }
    }

    @Test fun corsPreflightValidatesMethodAndHeadersThenFiltersResponseHeaders() {
        MockWebServer().use { server ->
            server.start()
            val source = "https://document.example"
            server.enqueue(
                MockResponse.Builder()
                    .addHeader("Access-Control-Allow-Origin", source)
                    .addHeader("Access-Control-Allow-Methods", "PATCH")
                    .addHeader("Access-Control-Allow-Headers", "content-type, x-trace")
                    .build(),
            )
            server.enqueue(
                MockResponse.Builder()
                    .addHeader("Access-Control-Allow-Origin", source)
                    .addHeader("Access-Control-Expose-Headers", "X-Visible")
                    .addHeader("Content-Type", "application/json")
                    .addHeader("X-Visible", "yes")
                    .addHeader("X-Hidden", "no")
                    .addHeader("Set-Cookie", "secret=1")
                    .body("{\"ok\":true}")
                    .build(),
            )

            val result = NativeScriptResourceTransport(null).load(
                sourceOrigin = source,
                request = NativeScriptResourceTransport.ResourceRequest(
                    url = server.url("/resource").toString(),
                    method = "PATCH",
                    headers = listOf(
                        NativeScriptResourceTransport.Header("Content-Type", "application/json"),
                        NativeScriptResourceTransport.Header("X-Trace", "123"),
                    ),
                ),
            )

            val preflight = server.takeRequest()
            assertEquals("OPTIONS", preflight.method)
            assertEquals(source, preflight.headers["Origin"])
            assertEquals("PATCH", preflight.headers["Access-Control-Request-Method"])
            assertEquals("content-type, x-trace", preflight.headers["Access-Control-Request-Headers"])
            val actual = server.takeRequest()
            assertEquals("PATCH", actual.method)
            assertEquals("application/json", actual.headers["Content-Type"])
            assertEquals("123", actual.headers["X-Trace"])
            assertEquals(
                "yes",
                result.headers.entries.firstOrNull { it.key.equals("X-Visible", ignoreCase = true) }?.value,
            )
            assertFalse(result.headers.containsKey("X-Hidden"))
            assertFalse(result.headers.keys.any { it.equals("Set-Cookie", true) })
            assertEquals("cors", result.type)
        }
    }

    @Test fun corsPreflightDoesNotTreatAuthorizationAsAllowedByWildcard() {
        MockWebServer().use { server ->
            server.start()
            val source = "https://document.example"
            server.enqueue(
                MockResponse.Builder()
                    .addHeader("Access-Control-Allow-Origin", source)
                    .addHeader("Access-Control-Allow-Methods", "GET")
                    .addHeader("Access-Control-Allow-Headers", "*")
                    .build(),
            )
            try {
                NativeScriptResourceTransport(null).load(
                    source,
                    NativeScriptResourceTransport.ResourceRequest(
                        url = server.url("/resource").toString(),
                        headers = listOf(NativeScriptResourceTransport.Header("Authorization", "Bearer user")),
                    ),
                )
                fail("Authorization must be explicitly allowed by CORS")
            } catch (e: IllegalStateException) {
                assertTrue(e.message.orEmpty().contains("requested headers"))
            }
            val preflight = server.takeRequest()
            assertEquals("OPTIONS", preflight.method)
            assertEquals("authorization", preflight.headers["Access-Control-Request-Headers"])
            assertEquals(1, server.requestCount)
        }
    }

    @Test fun opaqueFetchHidesStatusHeadersAndBodyButClassicScriptKeepsHostBytes() {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(
                MockResponse.Builder()
                    .addHeader("Content-Type", "text/plain")
                    .addHeader("X-Secret", "not-script-visible")
                    .body("opaque bytes")
                    .build(),
            )
            server.enqueue(
                MockResponse.Builder()
                    .addHeader("Content-Type", "text/javascript; charset=UTF-8")
                    .addHeader("X-Secret", "not-script-visible")
                    .body("globalThis.scriptLoaded = true;")
                    .build(),
            )
            val transport = NativeScriptResourceTransport(null)
            val source = "https://document.example"
            val opaque = transport.load(
                source,
                NativeScriptResourceTransport.ResourceRequest(
                    url = server.url("/opaque").toString(),
                    mode = NativeScriptResourceTransport.Mode.NO_CORS,
                ),
            )
            assertEquals("opaque", opaque.type)
            assertEquals(0, opaque.status)
            assertTrue(opaque.headers.isEmpty())
            assertNull(opaque.body)

            val scriptBytes = "globalThis.scriptLoaded = true;".toByteArray()
            val script = transport.load(
                source,
                NativeScriptResourceTransport.ResourceRequest(
                    url = server.url("/classic.js").toString(),
                    kind = NativeScriptResourceTransport.Kind.CLASSIC_SCRIPT,
                ),
            )
            assertEquals("script", script.type)
            assertEquals("text/javascript", script.mimeType)
            assertEquals("UTF-8", script.charset)
            assertTrue(script.headers.isEmpty())
            assertArrayEquals(scriptBytes, script.body)
        }
    }

    @Test fun classicScriptAppliesCrossoriginCorsAndStrongestSriMetadata() {
        MockWebServer().use { server ->
            server.start()
            val script = "globalThis.ok = 1;".toByteArray()
            server.enqueue(
                MockResponse.Builder()
                    .addHeader("Access-Control-Allow-Origin", "https://document.example")
                    .addHeader("Access-Control-Allow-Credentials", "true")
                    .addHeader("Content-Type", "application/javascript")
                    .body(String(script, Charsets.UTF_8))
                    .build(),
            )
            val result = NativeScriptResourceTransport(null).load(
                sourceOrigin = "https://document.example",
                request = NativeScriptResourceTransport.ResourceRequest(
                    url = server.url("/script.js").toString(),
                    kind = NativeScriptResourceTransport.Kind.CLASSIC_SCRIPT,
                    crossOrigin = "use-credentials",
                    integrity = "${sri("sha256", "wrong".toByteArray())} ${sri("sha384", script)}",
                ),
            )
            assertEquals("script", result.type)
            assertArrayEquals(script, result.body)
            assertEquals("https://document.example", server.takeRequest().headers["Origin"])
        }
    }

    @Test fun unsupportedOrFailedScriptIntegrityAndMimeAreRejected() {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(
                MockResponse.Builder()
                    .addHeader("Content-Type", "text/javascript")
                    .body("alert(1)")
                    .build(),
            )
            server.enqueue(
                MockResponse.Builder()
                    .addHeader("Content-Type", "text/html")
                    .body("not JavaScript")
                    .build(),
            )
            val transport = NativeScriptResourceTransport(null)
            try {
                transport.load(
                    origin(server.url("/document")),
                    NativeScriptResourceTransport.ResourceRequest(
                        url = server.url("/bad-hash.js").toString(),
                        kind = NativeScriptResourceTransport.Kind.CLASSIC_SCRIPT,
                        integrity = sri("sha256", "different".toByteArray()),
                    ),
                )
                fail("Mismatched integrity must be rejected")
            } catch (e: IllegalArgumentException) {
                assertTrue(e.message.orEmpty().contains("integrity"))
            }
            try {
                transport.load(
                    "https://document.example",
                    NativeScriptResourceTransport.ResourceRequest(
                        url = server.url("/html.js").toString(),
                        kind = NativeScriptResourceTransport.Kind.CLASSIC_SCRIPT,
                    ),
                )
                fail("Unsupported MIME must be rejected")
            } catch (e: IllegalArgumentException) {
                assertTrue(e.message.orEmpty().contains("MIME"))
            }
        }
    }

    @Test fun crossOriginNoCorsScriptWithIntegrityIsRejectedBecauseItCannotBeVerified() {
        MockWebServer().use { server ->
            server.start()
            val script = "globalThis.ok = true;".toByteArray()
            try {
                NativeScriptResourceTransport(null).load(
                    sourceOrigin = "https://document.example",
                    request = NativeScriptResourceTransport.ResourceRequest(
                        url = server.url("/script.js").toString(),
                        kind = NativeScriptResourceTransport.Kind.CLASSIC_SCRIPT,
                        integrity = sri("sha256", script),
                    ),
                )
                fail("Cross-origin no-cors scripts cannot be integrity checked")
            } catch (e: IllegalArgumentException) {
                assertTrue(e.message.orEmpty().contains("requires CORS"))
            }
            assertEquals(0, server.requestCount)
        }
    }

    @Test fun rejectsForbiddenHeadersNoCorsDowngradeAndOversizedResponses() {
        val transport = NativeScriptResourceTransport(null, responseLimit = 3)
        for (header in listOf("Origin" to "https://elsewhere", "Cookie" to "a=b")) {
            try {
                transport.load(
                    "https://document.example",
                    NativeScriptResourceTransport.ResourceRequest(
                        url = "https://document.example/resource",
                        headers = listOf(NativeScriptResourceTransport.Header(header.first, header.second)),
                    ),
                )
                fail("Forbidden header ${header.first} must be rejected")
            } catch (_: IllegalArgumentException) { }
        }
        try {
            transport.load(
                "https://document.example",
                NativeScriptResourceTransport.ResourceRequest(
                    url = "https://external.example/resource",
                    method = "PATCH",
                    mode = NativeScriptResourceTransport.Mode.NO_CORS,
                ),
            )
            fail("no-cors PATCH must be rejected")
        } catch (_: IllegalArgumentException) { }

        try {
            transport.load(
                "https://document.example",
                NativeScriptResourceTransport.ResourceRequest(
                    url = "https://document.example/same-origin",
                    method = "PATCH",
                    mode = NativeScriptResourceTransport.Mode.NO_CORS,
                ),
            )
            fail("no-cors restrictions must apply to same-origin requests too")
        } catch (_: IllegalArgumentException) { }

        MockWebServer().use { server ->
            server.enqueue(MockResponse.Builder().body("four").build())
            server.start()
            try {
                transport.load(
                    origin(server.url("/document")),
                    NativeScriptResourceTransport.ResourceRequest(
                        url = server.url("/large").toString(),
                    ),
                )
                fail("The configured response limit must apply")
            } catch (e: IllegalStateException) {
                assertTrue(e.message.orEmpty().contains("size limit"))
            }
        }
    }

    @Test fun bodylessFetchResponsesAreRepresentedWithoutAResponseBody() {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse.Builder().code(204).build())
            server.enqueue(MockResponse.Builder().code(205).build())
            server.enqueue(MockResponse.Builder().code(304).build())
            server.enqueue(MockResponse.Builder().body("HEAD bodies are hidden").build())
            val transport = NativeScriptResourceTransport(null)
            val source = origin(server.url("/document"))
            val noContent = transport.load(
                source,
                NativeScriptResourceTransport.ResourceRequest(url = server.url("/no-content").toString()),
            )
            val resetContent = transport.load(
                source,
                NativeScriptResourceTransport.ResourceRequest(url = server.url("/reset").toString()),
            )
            val notModified = transport.load(
                source,
                NativeScriptResourceTransport.ResourceRequest(url = server.url("/cached").toString()),
            )
            val head = transport.load(
                source,
                NativeScriptResourceTransport.ResourceRequest(
                    url = server.url("/head").toString(),
                    method = "HEAD",
                ),
            )
            assertNull(noContent.body)
            assertNull(resetContent.body)
            assertNull(notModified.body)
            assertNull(head.body)
        }
    }

    @Test fun fetchCredentialsGateCookiesAndPreflightNeverSendsOrAcceptsThem() {
        MockWebServer().use { sourceServer ->
            MockWebServer().use { targetServer ->
                sourceServer.start()
                targetServer.enqueue(
                    MockResponse.Builder()
                        .addHeader("Access-Control-Allow-Origin", origin(sourceServer.url("/")))
                        .addHeader("Set-Cookie", "ignored=omit; Path=/; SameSite=None; Secure")
                        .body("omitted")
                        .build(),
                )
                targetServer.enqueue(
                    MockResponse.Builder()
                        .code(204)
                        .addHeader("Access-Control-Allow-Origin", origin(sourceServer.url("/")))
                        .addHeader("Access-Control-Allow-Credentials", "true")
                        .addHeader("Access-Control-Allow-Methods", "PATCH")
                        .addHeader("Access-Control-Allow-Headers", "x-trace")
                        .addHeader("Set-Cookie", "ignored=preflight; Path=/; SameSite=None; Secure")
                        .build(),
                )
                targetServer.enqueue(
                    MockResponse.Builder()
                        .addHeader("Access-Control-Allow-Origin", origin(sourceServer.url("/")))
                        .addHeader("Access-Control-Allow-Credentials", "true")
                        .addHeader("Set-Cookie", "sid=updated; Path=/; SameSite=None; Secure")
                        .body("patched")
                        .build(),
                )
                targetServer.enqueue(
                    MockResponse.Builder()
                        .addHeader("Access-Control-Allow-Origin", origin(sourceServer.url("/")))
                        .addHeader("Set-Cookie", "ignored=same-origin; Path=/; SameSite=None; Secure")
                        .body("same-origin credentials mode")
                        .build(),
                )
                targetServer.enqueue(MockResponse.Builder().body("verified").build())
                targetServer.start()

                val sourcePage = sourceServer.url("/page")
                val targetPage = targetServer.url("/page")
                val cookies = NativeDocumentCookies()
                cookies.receive(
                    targetPage,
                    listOf("sid=seed; Path=/; SameSite=None; Secure"),
                    CookieRequestContext(
                        initiatorUrl = sourcePage,
                        topLevelUrl = sourcePage,
                    ),
                )
                var jarLoads = 0
                val ambientJar = object : CookieJar {
                    override fun loadForRequest(url: HttpUrl): List<Cookie> {
                        jarLoads++
                        return listOf(checkNotNull(Cookie.parse(url, "ambient=must-not-leak; Path=/")))
                    }

                    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) = Unit
                }
                val transport = NativeScriptResourceTransport(
                    null,
                    OkHttpClient.Builder().cookieJar(ambientJar).build(),
                    cookies = cookies,
                )
                val sourceOrigin = origin(sourcePage)
                val omitted = transport.load(
                    sourceOrigin,
                    NativeScriptResourceTransport.ResourceRequest(
                        url = targetServer.url("/omit").toString(),
                        credentials = NativeScriptResourceTransport.Credentials.OMIT,
                    ),
                    initiatorUrl = sourcePage.toString(),
                    topLevelUrl = sourcePage.toString(),
                )
                val omittedRequest = targetServer.takeRequest()
                assertNull(omittedRequest.headers["Cookie"])
                assertEquals(true, omitted.nativeSetCookieProcessed)

                val patched = transport.load(
                    sourceOrigin,
                    NativeScriptResourceTransport.ResourceRequest(
                        url = targetServer.url("/patch").toString(),
                        method = "PATCH",
                        headers = listOf(
                            NativeScriptResourceTransport.Header("X-Trace", "trace"),
                        ),
                        credentials = NativeScriptResourceTransport.Credentials.INCLUDE,
                    ),
                    initiatorUrl = sourcePage.toString(),
                    topLevelUrl = sourcePage.toString(),
                )
                val preflight = targetServer.takeRequest()
                val actual = targetServer.takeRequest()
                assertEquals("OPTIONS", preflight.method)
                assertNull(preflight.headers["Cookie"])
                assertEquals("PATCH", actual.method)
                assertEquals("sid=seed", actual.headers["Cookie"])
                assertEquals(opaqueCookieRequestKey("sid=seed"), patched.nativeCookieRequestKey)
                assertEquals(true, patched.nativeSetCookieProcessed)
                assertFalse(patched.headers.keys.any { it.equals("Set-Cookie", ignoreCase = true) })

                transport.load(
                    sourceOrigin,
                    NativeScriptResourceTransport.ResourceRequest(
                        url = targetServer.url("/same-origin-mode").toString(),
                        credentials = NativeScriptResourceTransport.Credentials.SAME_ORIGIN,
                    ),
                    initiatorUrl = sourcePage.toString(),
                    topLevelUrl = sourcePage.toString(),
                )
                val sameOriginModeRequest = targetServer.takeRequest()
                assertNull(sameOriginModeRequest.headers["Cookie"])

                val sameOrigin = origin(targetPage)
                transport.load(
                    sameOrigin,
                    NativeScriptResourceTransport.ResourceRequest(
                        url = targetServer.url("/verify").toString(),
                        credentials = NativeScriptResourceTransport.Credentials.SAME_ORIGIN,
                    ),
                    initiatorUrl = targetPage.toString(),
                    topLevelUrl = targetPage.toString(),
                )
                val verified = targetServer.takeRequest()
                assertEquals("sid=updated", verified.headers["Cookie"])
                assertEquals(0, jarLoads)
            }
        }
    }

    @Test fun credentialedCookieIsStoredBeforeCorsBlocksResponseRead() {
        MockWebServer().use { sourceServer ->
            MockWebServer().use { targetServer ->
                sourceServer.start()
                targetServer.enqueue(
                    MockResponse.Builder()
                        .addHeader("Access-Control-Allow-Origin", "*")
                        .addHeader("Set-Cookie", "cors=stored; Path=/; SameSite=None; Secure")
                        .body("unreadable")
                        .build(),
                )
                targetServer.enqueue(MockResponse.Builder().body("same origin").build())
                targetServer.start()

                val sourcePage = sourceServer.url("/page")
                val cookies = NativeDocumentCookies()
                val transport = NativeScriptResourceTransport(null, cookies = cookies)
                try {
                    transport.load(
                        origin(sourcePage),
                        NativeScriptResourceTransport.ResourceRequest(
                            url = targetServer.url("/cors").toString(),
                            credentials = NativeScriptResourceTransport.Credentials.INCLUDE,
                        ),
                        initiatorUrl = sourcePage.toString(),
                        topLevelUrl = sourcePage.toString(),
                    )
                    fail("Credentialed CORS must reject wildcard origins")
                } catch (error: IllegalStateException) {
                    assertTrue(error.message.orEmpty().contains("CORS response"))
                }

                val targetPage = targetServer.url("/verify")
                transport.load(
                    origin(targetPage),
                    NativeScriptResourceTransport.ResourceRequest(
                        url = targetPage.toString(),
                        credentials = NativeScriptResourceTransport.Credentials.SAME_ORIGIN,
                    ),
                    initiatorUrl = targetPage.toString(),
                    topLevelUrl = targetPage.toString(),
                )
                val blockedCorsRequest = targetServer.takeRequest()
                assertNull(blockedCorsRequest.headers["Cookie"])
                val verificationRequest = targetServer.takeRequest()
                assertEquals("cors=stored", verificationRequest.headers["Cookie"])
            }
        }
    }

    @Test fun crossSiteRedirectKeepsNoneCookiesAndDropsStrictAndLaxCookies() {
        MockWebServer().use { sourceServer ->
            MockWebServer().use { targetServer ->
                sourceServer.start()
                targetServer.start()
                val dns = Dns { listOf(InetAddress.getByName("127.0.0.1")) }
                val client = OkHttpClient.Builder().dns(dns).build()
                val sourcePage = sourceServer.url("/page")
                    .newBuilder().host("127.0.0.1").build()
                val sourceStart = sourceServer.url("/start")
                    .newBuilder().host("127.0.0.1").build()
                val targetPage = targetServer.url("/final")
                    .newBuilder().host("localhost").build()
                sourceServer.enqueue(
                    MockResponse.Builder()
                        .code(302)
                        .addHeader("Location", targetPage.toString())
                        .build(),
                )
                targetServer.enqueue(
                    MockResponse.Builder()
                        .addHeader("Access-Control-Allow-Origin", origin(sourcePage))
                        .addHeader("Access-Control-Allow-Credentials", "true")
                        .body("final")
                        .build(),
                )

                val cookies = NativeDocumentCookies()
                // Loopback aliases are secure cookie origins but distinct schemeful sites.
                cookies.receive(
                    targetPage,
                    listOf(
                        "strict=1; Path=/; SameSite=Strict",
                        "lax=1; Path=/; SameSite=Lax",
                        "none=1; Path=/; SameSite=None; Secure",
                    ),
                    CookieRequestContext(
                        initiatorUrl = targetPage,
                        topLevelUrl = targetPage,
                    ),
                )
                val response = NativeScriptResourceTransport(
                    null,
                    client,
                    cookies = cookies,
                ).load(
                    origin(sourcePage),
                    NativeScriptResourceTransport.ResourceRequest(
                        url = sourceStart.toString(),
                        credentials = NativeScriptResourceTransport.Credentials.INCLUDE,
                    ),
                    initiatorUrl = sourcePage.toString(),
                    topLevelUrl = sourcePage.toString(),
                )
                assertNull(sourceServer.takeRequest().headers["Cookie"])
                val redirectedRequest = targetServer.takeRequest()
                assertEquals("none=1", redirectedRequest.headers["Cookie"])
                assertEquals(opaqueCookieRequestKey("none=1"), response.nativeCookieRequestKey)
                assertEquals("final", response.body?.decodeToString())
            }
        }
    }

    @Test fun cookieSiteContextKeepsDocumentAndTopLevelUrlsDistinct() {
        MockWebServer().use { topLevelServer ->
            MockWebServer().use { documentServer ->
                topLevelServer.start()
                documentServer.enqueue(MockResponse.Builder().body("same origin").build())
                documentServer.start()

                val client = OkHttpClient.Builder()
                    .dns(Dns { listOf(InetAddress.getByName("127.0.0.1")) })
                    .build()
                val documentUrl = documentServer.url("/frame")
                    .newBuilder().host("frame.example.test").build()
                val topLevelUrl = topLevelServer.url("/top")
                    .newBuilder().host("top.other.test").build()
                val requestUrl = documentServer.url("/resource")
                    .newBuilder().host("frame.example.test").build()
                val cookies = NativeDocumentCookies()
                cookies.receive(
                    requestUrl,
                    listOf("strict=1; Path=/; SameSite=Strict"),
                    CookieRequestContext(
                        initiatorUrl = documentUrl,
                        topLevelUrl = documentUrl,
                    ),
                )

                NativeScriptResourceTransport(null, client, cookies = cookies).load(
                    origin(documentUrl),
                    NativeScriptResourceTransport.ResourceRequest(
                        url = requestUrl.toString(),
                        credentials = NativeScriptResourceTransport.Credentials.SAME_ORIGIN,
                    ),
                    initiatorUrl = documentUrl.toString(),
                    topLevelUrl = topLevelUrl.toString(),
                    referrerUrl = documentUrl.toString(),
                )

                val request = documentServer.takeRequest()
                assertNotNull(request.headers["Referer"])
                assertNull(request.headers["Cookie"])
            }
        }
    }

    // ---- credential boundary ----

    private val pairedIdentityHeaders = listOf("Authorization", "X-Pirc-Management", "X-Pirc-Request", "Cookie")

    @Test fun requestsFromScriptsAndSubresourcesCarryNoPairedIdentityEvenOnThePairedOrigin() {
        MockWebServer().use { gateway ->
            gateway.start()
            val page = gateway.url("/?session=SESSION-ID-3")
            val cookies = NativeDocumentCookies()
            cookies.receive(
                gateway.url("/"), listOf("seed=1; Path=/"),
                CookieRequestContext(initiatorUrl = page, topLevelUrl = page, topLevelNavigation = true),
            )
            val p = pairing(gateway)
            // The declared initiator is the default: page content.
            val transport = NativeScriptResourceTransport(p, cookies = cookies)
            val source = origin(page)
            val kinds = listOf(
                NativeScriptResourceTransport.Kind.FETCH to "application/json",
                NativeScriptResourceTransport.Kind.IMAGE to "image/png",
                NativeScriptResourceTransport.Kind.STYLESHEET to "text/css",
                NativeScriptResourceTransport.Kind.CLASSIC_SCRIPT to "text/javascript",
            )
            for ((kind, mime) in kinds) {
                gateway.enqueue(
                    MockResponse.Builder().addHeader("Content-Type", mime)
                        .addHeader("Set-Cookie", "gw=1; Path=/").body("x").build(),
                )
                transport.load(
                    source,
                    NativeScriptResourceTransport.ResourceRequest(
                        url = gateway.url("/api/sessions/s/resource").toString(),
                        kind = kind,
                        credentials = NativeScriptResourceTransport.Credentials.INCLUDE,
                        crossOrigin = if (kind == NativeScriptResourceTransport.Kind.FETCH) null else "use-credentials",
                    ),
                    referrerUrl = page.toString(), initiatorUrl = page.toString(), topLevelUrl = page.toString(),
                )
                val request = gateway.takeRequest()
                pairedIdentityHeaders.forEach { assertNull("$kind $it", request.headers[it]) }
            }
            gateway.enqueue(MockResponse.Builder().body("{}").build())
            transport.load(
                source,
                NativeScriptResourceTransport.ResourceRequest(
                    url = gateway.url("/api/sessions/s/commands").toString(),
                    method = "POST", body = "{}".toByteArray(),
                    credentials = NativeScriptResourceTransport.Credentials.INCLUDE,
                ),
                referrerUrl = page.toString(), initiatorUrl = page.toString(), topLevelUrl = page.toString(),
            )
            val post = gateway.takeRequest()
            pairedIdentityHeaders.forEach { assertNull(it, post.headers[it]) }
            // The page is not named as the Gateway origin: Origin is opaque.
            assertEquals("null", post.headers["Origin"])
            assertEquals(
                "seed=1",
                cookies.requestHeader(
                    gateway.url("/"),
                    CookieRequestContext(initiatorUrl = page, topLevelUrl = page, topLevelNavigation = true),
                ),
            )
        }
    }

    @Test fun scriptsCannotAddRequestShapeOrManagementHeaders() {
        MockWebServer().use { server ->
            server.start()
            val source = origin(server.url("/"))
            val transport = NativeScriptResourceTransport(pairing(server))
            for (name in listOf("X-Pirc-Request", "x-pirc-request", "X-Pirc-Management", "X-PIRC-Anything", "x-pirc-first-send-contract")) {
                assertThrows(name, IllegalArgumentException::class.java) {
                    transport.load(
                        source,
                        NativeScriptResourceTransport.ResourceRequest(
                            url = server.url("/api/x").toString(), method = "POST", body = "{}".toByteArray(),
                            mode = NativeScriptResourceTransport.Mode.SAME_ORIGIN,
                            headers = listOf(NativeScriptResourceTransport.Header(name, "1")),
                        ),
                    )
                }
            }
            assertEquals(0, server.requestCount)
        }
    }

    @Test fun scriptOwnedRequestsFromThePairedOriginNeverNameItInRefererOrOrigin() {
        MockWebServer().use { gateway -> MockWebServer().use { external ->
            gateway.start(); external.start()
            val internal = gateway.url("/?session=SESSION-ID-4").toString()
            val gatewayOrigin = origin(gateway.url("/"))
            val transport = NativeScriptResourceTransport(pairing(gateway))
            val cases = listOf(
                NativeScriptResourceTransport.ResourceRequest(
                    url = external.url("/fetch").toString(), referrerPolicy = "unsafe-url",
                ),
                NativeScriptResourceTransport.ResourceRequest(
                    url = external.url("/image").toString(), kind = NativeScriptResourceTransport.Kind.IMAGE,
                    crossOrigin = "anonymous", referrerPolicy = "unsafe-url",
                ),
                NativeScriptResourceTransport.ResourceRequest(
                    url = external.url("/style").toString(), kind = NativeScriptResourceTransport.Kind.STYLESHEET,
                    crossOrigin = "anonymous", referrerPolicy = "origin",
                ),
                NativeScriptResourceTransport.ResourceRequest(
                    url = external.url("/post").toString(), method = "POST", body = "a".toByteArray(),
                    referrerPolicy = "unsafe-url",
                ),
            )
            for (request in cases) {
                external.enqueue(
                    MockResponse.Builder().addHeader("Access-Control-Allow-Origin", "*")
                        .addHeader("Content-Type", if (request.kind == NativeScriptResourceTransport.Kind.STYLESHEET) "text/css" else "text/plain")
                        .body("ok").build(),
                )
                transport.load(
                    gatewayOrigin, request, referrerUrl = internal,
                    initiatorUrl = internal, topLevelUrl = internal,
                )
                val seen = external.takeRequest()
                assertNull(seen.headers["Referer"])
                assertTrue(seen.headers["Origin"] == null || seen.headers["Origin"] == "null")
                seen.headers.forEach { (name, value) ->
                    assertFalse("$name: $value", value.contains("SESSION-ID-4"))
                    assertFalse("$name: $value", value.contains(gatewayOrigin))
                }
            }
        } }
    }

    @Test fun aThirdPartyDocumentKeepsItsOwnRefererBehaviour() {
        MockWebServer().use { gateway -> MockWebServer().use { external ->
            gateway.start(); external.start()
            val page = external.url("/doc?x=1").toString()
            external.enqueue(MockResponse.Builder().addHeader("Content-Type", "text/plain").body("ok").build())
            NativeScriptResourceTransport(pairing(gateway)).load(
                origin(external.url("/")),
                NativeScriptResourceTransport.ResourceRequest(
                    url = external.url("/next").toString(), mode = NativeScriptResourceTransport.Mode.NO_CORS,
                    referrerPolicy = "unsafe-url",
                ),
                referrerUrl = page,
            )
            assertEquals(page, external.takeRequest().headers["Referer"])
        } }
    }

    private fun pairing(server: MockWebServer): Pairing =
        Pairing(server.url("/").toString().trimEnd('/'), "device-token")

    /** Test stand-in for a request the app itself started (the only way to carry the credential). */
    private fun appInitiated(pairing: Pairing) = AppRequestAuthority().issue(pairing)

    private fun origin(url: okhttp3.HttpUrl): String =
        "${url.scheme}://${url.host}:${url.port}"

    private fun sri(algorithm: String, bytes: ByteArray): String {
        val jca = when (algorithm) {
            "sha256" -> "SHA-256"
            "sha384" -> "SHA-384"
            else -> "SHA-512"
        }
        val digest = MessageDigest.getInstance(jca).digest(bytes)
        return "$algorithm-${Base64.getEncoder().encodeToString(digest)}"
    }
}
