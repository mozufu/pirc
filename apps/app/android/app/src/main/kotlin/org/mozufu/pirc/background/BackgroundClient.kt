package org.mozufu.pirc.background

import android.content.Context
import java.io.IOException
import java.net.Proxy
import java.util.UUID
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject
import org.mozufu.pirc.credentials.KeystoreCredentialStore

/** What became of one background request. */
sealed interface BackgroundResult {
    /** 2xx; [body] is the JSON reply, or null when it had none. */
    data class Done(val body: JSONObject?) : BackgroundResult

    /**
     * The Gateway refused the request, so nothing happened. [code] is the Gateway's
     * error code; a 3xx is `redirect_refused`. A `401` means pair again.
     */
    data class Refused(val status: Int, val code: String?, val message: String?) : BackgroundResult

    /** No token is stored: the device is not paired. Nothing was sent. */
    data object Unpaired : BackgroundResult

    /**
     * A read failed before an answer came, or the token could not be read and nothing
     * was sent. Trying again is safe.
     */
    data class Unreachable(val cause: Throwable) : BackgroundResult

    /**
     * "Not sure it arrived": a send whose outcome is unknown. That is a timeout or a
     * dropped connection after the request may have gone out, or any 5xx (a proxy's
     * error, the Gateway's `node_offline`, `node_timeout` or `outcome_unknown`). It is
     * never sent again (N8); the app reads the state to find out.
     */
    data class NotSure(val commandId: String, val cause: Throwable?) : BackgroundResult
}

/**
 * The slim client that push receipt and the quick-reply overlay use without the Flutter
 * engine (plans/client.md, Background client). It reads only the compact routes and
 * sends answers and schedule decisions; nothing else.
 *
 * Calls block: run them off the main thread. [tokens] reads the device token from the
 * Keystore for each request. [clientId] is the app's client ID, which answers name.
 *
 * Every send has a client-generated command ID. The ID stays on the phone: the answer
 * and schedule routes refuse unknown body keys, so it names the user's action in a
 * [BackgroundResult.NotSure] and nothing more. This instance refuses to send an ID that
 * is in flight or whose outcome is unknown, but it remembers that only while it lives:
 * callers (push actions, the overlay) must keep their own uncertain IDs and read the
 * state instead of sending again.
 */
class BackgroundClient(
    private val gateway: HttpUrl,
    private val clientId: String,
    private val tokens: () -> String?,
    private val http: OkHttpClient = GatewayHttp.client(),
    private val newCommandId: () -> String = { UUID.randomUUID().toString() },
) {
    private val lock = Any()
    private val inFlight = mutableSetOf<String>()
    private val uncertain = mutableSetOf<String>()

    /** Command IDs whose outcome is not known. */
    val notSure: Set<String> get() = synchronized(lock) { uncertain.toSet() }

    /** `GET /api/sessions/{id}/interactions/{iid}`: the compact state of one question. */
    fun interaction(sessionId: String, interactionId: String): BackgroundResult =
        read(url("api", "sessions", sessionId, "interactions", interactionId))

    /** `GET /api/schedules/{id}/runs/{runId}`: the state of one scheduled run. */
    fun scheduleRun(scheduleId: String, runId: String): BackgroundResult =
        read(url("api", "schedules", scheduleId, "runs", runId))

    /**
     * `POST /api/sessions/{id}/interactions/{iid}/answer` with `{clientId, answer}`, as the
     * app's question card sends it. [answer] is the answer object (for example
     * `{"value": "yes"}`).
     */
    fun answer(
        sessionId: String,
        interactionId: String,
        answer: JSONObject,
        commandId: String = newCommandId(),
    ): BackgroundResult = send(
        commandId,
        url("api", "sessions", sessionId, "interactions", interactionId, "answer"),
        JSONObject().put("clientId", clientId).put("answer", answer).toString().toRequestBody(JSON),
    )

    /** Allows a missed run: `POST /api/schedules/{id}/run` with `{runId}`. */
    fun allowRun(scheduleId: String, runId: String, commandId: String = newCommandId()): BackgroundResult =
        send(
            commandId,
            url("api", "schedules", scheduleId, "run"),
            JSONObject().put("runId", runId).toString().toRequestBody(JSON),
        )

    /** Dismisses a missed run: `POST /api/schedules/{id}/runs/{runId}/dismiss`. */
    fun dismissRun(scheduleId: String, runId: String, commandId: String = newCommandId()): BackgroundResult =
        send(commandId, url("api", "schedules", scheduleId, "runs", runId, "dismiss"), EMPTY)

    private fun url(vararg segments: String): HttpUrl = gateway.newBuilder()
        .apply { segments.forEach { addPathSegment(it) } }
        .build()

    private fun read(url: HttpUrl): BackgroundResult {
        val token = try {
            tokens()
        } catch (error: Exception) {
            return BackgroundResult.Unreachable(error)
        } ?: return BackgroundResult.Unpaired
        return try {
            withToken(token, Request.Builder().url(url).get(), ::classify)
        } catch (error: IOException) {
            BackgroundResult.Unreachable(error)
        }
    }

    private fun send(commandId: String, url: HttpUrl, body: RequestBody): BackgroundResult {
        synchronized(lock) {
            check(commandId !in uncertain) { "Command $commandId has an unknown outcome; read the state instead" }
            check(inFlight.add(commandId)) { "Command $commandId is being sent" }
        }
        var result: BackgroundResult? = null
        try {
            result = sendOnce(commandId, url, body)
            return result
        } finally {
            synchronized(lock) {
                inFlight -= commandId
                // An unexpected error also leaves the outcome unknown.
                if (result == null || result is BackgroundResult.NotSure) uncertain += commandId
            }
        }
    }

    private fun sendOnce(commandId: String, url: HttpUrl, body: RequestBody): BackgroundResult {
        val token = try {
            tokens()
        } catch (error: Exception) {
            return BackgroundResult.Unreachable(error)
        } ?: return BackgroundResult.Unpaired
        return try {
            withToken(token, Request.Builder().url(url).post(body)) { response ->
                val result = classify(response)
                // Any 5xx may come after the Gateway or the node acted: a proxy's
                // error, `node_offline`, `node_timeout`, `outcome_unknown`.
                if (result is BackgroundResult.Refused && response.code >= 500) {
                    BackgroundResult.NotSure(commandId, null)
                } else {
                    result
                }
            }
        } catch (error: IOException) {
            BackgroundResult.NotSure(commandId, error)
        }
    }

    /**
     * Sends with [token]. A `401` is a known refusal: the token is read again and, only
     * if it changed (the app rotated it meanwhile), the request is sent once more.
     */
    private fun withToken(
        token: String,
        request: Request.Builder,
        handle: (Response) -> BackgroundResult,
    ): BackgroundResult {
        val first = execute(request, token, handle)
        if (first !is BackgroundResult.Refused || first.status != 401) return first
        val fresh = runCatching(tokens).getOrNull()
        if (fresh.isNullOrEmpty() || fresh == token) return first
        return execute(request, fresh, handle)
    }

    private fun execute(
        request: Request.Builder,
        token: String,
        handle: (Response) -> BackgroundResult,
    ): BackgroundResult = http.newCall(request.header("Authorization", "Bearer $token").header("Accept", "application/json").build())
        .execute()
        .use(handle)

    private fun classify(response: Response): BackgroundResult {
        val text = response.body.string()
        val json = text.takeIf { it.isNotBlank() }?.let { runCatching { JSONObject(it) }.getOrNull() }
        if (response.isSuccessful) return BackgroundResult.Done(json)
        if (response.code in 300..399) {
            return BackgroundResult.Refused(response.code, "redirect_refused", "The gateway answered with a redirect; it was not followed.")
        }
        val error = json?.optJSONObject("error")
        return BackgroundResult.Refused(
            response.code,
            error?.optString("code")?.takeIf { it.isNotEmpty() },
            error?.optString("message")?.takeIf { it.isNotEmpty() },
        )
    }

    companion object {
        private val JSON = "application/json".toMediaType()
        private val EMPTY = ByteArray(0).toRequestBody(null)

        /** The client of the app: the token from the Keystore, the one OkHttp factory. */
        fun create(
            context: Context,
            gateway: HttpUrl,
            clientId: String,
            proxy: (() -> Proxy?)? = null,
        ): BackgroundClient {
            val store = KeystoreCredentialStore.create(context)
            return BackgroundClient(gateway, clientId, store::read, GatewayHttp.client(proxy))
        }
    }
}
