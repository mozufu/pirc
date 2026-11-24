package dev.pirc.pirc_mobile

import java.io.EOFException
import java.io.IOException
import java.net.SocketException
import okhttp3.Interceptor
import okhttp3.Response

/** A pooled HTTP connection may have been closed while idle. Only replay reads. */
class ReadRecovery : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        try {
            return chain.proceed(request)
        } catch (error: IOException) {
            val closedSocket = generateSequence<Throwable>(error) { it.cause }
                .any { it is EOFException || it is SocketException }
            if (request.method !in setOf("GET", "HEAD") || request.header("Upgrade") != null ||
                chain.call().isCanceled() || !closedSocket) throw error
            // One fresh attempt; a second failure is surfaced. No POST/PATCH/DELETE replay.
            return chain.proceed(request)
        }
    }
}
