package dev.pirc.pirc_mobile

import java.io.IOException
import java.util.concurrent.TimeUnit
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.SocketEffect
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.junit.Assert.*
import org.junit.Test

class ReadRecoveryTest {
    private fun client() = OkHttpClient.Builder().retryOnConnectionFailure(false)
        .addInterceptor(ReadRecovery()).readTimeout(3, TimeUnit.SECONDS).build()
    @Test fun disconnectedReadRecoversOnce() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build())
            server.enqueue(MockResponse.Builder().body("recovered").build())
            server.start()
            client().newCall(Request.Builder().url(server.url("/api/sessions")).build()).execute().use {
                assertEquals("recovered", it.body!!.string())
            }
            assertEquals(2, server.requestCount)
        }
    }
    @Test fun possiblyAcceptedMutationIsNeverReplayed() {
        for (method in listOf("POST", "PATCH", "DELETE")) MockWebServer().use { server ->
            server.enqueue(MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build())
            server.enqueue(MockResponse.Builder().body("must not be reached").build())
            server.start()
            try {
                client().newCall(Request.Builder().url(server.url("/api/operation"))
                    .method(method, "{}".toRequestBody()).build()).execute().close()
                fail("must expose uncertain mutation outcome")
            } catch (_: IOException) { }
            assertEquals(1, server.requestCount)
        }
    }
    @Test fun repeatedReadFailureIsBounded() {
        MockWebServer().use { server ->
            repeat(3) { server.enqueue(MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build()) }
            server.start()
            try {
                client().newCall(Request.Builder().url(server.url("/api/sessions")).build()).execute().close()
                fail("must report the second failure")
            } catch (_: IOException) { }
            assertEquals(2, server.requestCount)
        }
    }
}
