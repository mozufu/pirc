package org.mozufu.pirc.background

import java.io.IOException
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient

/**
 * The one OkHttp factory of the background client. Every client it makes:
 * - never follows a redirect (a 3xx is a refusal, as in the Dart client);
 * - never retries by itself: OkHttp's silent retry could send a POST twice (N8);
 * - sends `X-Pirc-Client: pirc-app/<apiVersion>`, and `X-Pirc-Request: 1` on every
 *   request that is not a GET;
 * - asks its proxy hook for each connection, so M10's embedded tailnet node can give
 *   its loopback proxy (null means a direct connection);
 * - waits longer than the Gateway waits for a node (30 s), so a slow node gives the
 *   Gateway's own answer instead of a local timeout.
 *
 * All clients share one connection pool and dispatcher. The device token is added per
 * request by [BackgroundClient], which reads it from the Keystore.
 */
object GatewayHttp {
    /** `apiVersion` in `packages/pirc_client/lib/pirc_client.dart`. */
    const val API_VERSION = 2
    const val CLIENT_HEADER = "X-Pirc-Client"
    const val CLIENT = "pirc-app/$API_VERSION"
    const val REQUEST_HEADER = "X-Pirc-Request"

    /** A direct connection, without a proxy hook. */
    val direct: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .retryOnConnectionFailure(false)
            .proxySelector(HookProxySelector { null })
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(35, TimeUnit.SECONDS)
            .callTimeout(40, TimeUnit.SECONDS)
            .addInterceptor { chain ->
                val request = chain.request()
                chain.proceed(
                    request.newBuilder()
                        .header(CLIENT_HEADER, CLIENT)
                        .apply { if (request.method != "GET") header(REQUEST_HEADER, "1") }
                        .build(),
                )
            }
            .build()
    }

    /** [direct], or with [proxy] asked for each connection; it shares [direct]'s pool. */
    fun client(proxy: (() -> Proxy?)? = null): OkHttpClient =
        if (proxy == null) direct else direct.newBuilder().proxySelector(HookProxySelector(proxy)).build()

    private class HookProxySelector(private val proxy: () -> Proxy?) : ProxySelector() {
        override fun select(uri: URI?): List<Proxy> = listOf(proxy() ?: Proxy.NO_PROXY)

        override fun connectFailed(uri: URI?, address: SocketAddress?, error: IOException?) {}
    }
}
