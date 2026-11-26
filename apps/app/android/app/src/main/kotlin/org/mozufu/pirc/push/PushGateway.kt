package org.mozufu.pirc.push

import java.io.IOException
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import org.mozufu.pirc.background.GatewayHttp
import org.mozufu.pirc.background.text

/** The Gateway refused a push request, or it did not arrive. The message is for logs. */
class PushGatewayException(val status: Int?, val code: String?, message: String) : IOException(message)

/**
 * This phone's push target at the Gateway (`/api/push*`), used without the Flutter engine:
 * a distributor can hand out a new endpoint at any time. Every request is safe to send
 * again (a subscription is keyed by its endpoint), so unlike [org.mozufu.pirc.background.BackgroundClient]
 * there is no command ID. Calls block; [tokens] reads the device token from the Keystore.
 */
class PushGateway(
    private val gateway: HttpUrl,
    private val tokens: () -> String?,
    private val http: OkHttpClient = GatewayHttp.client(),
) {
    /** `GET /api/push` → the VAPID public key the distributor registers with. */
    fun publicKey(): String = request("GET", null).text("publicKey")
        ?: throw PushGatewayException(null, null, "The gateway gave no push key")

    /** The target [id] as `GET /api/push` lists it, or null when the Gateway has none. */
    fun target(id: String): JSONObject? {
        val list = request("GET", null).optJSONArray("subscriptions") ?: return null
        for (i in 0 until list.length()) {
            val target = list.optJSONObject(i) ?: continue
            if (target.text("id") == id) return target
        }
        return null
    }

    /**
     * `POST /api/push/subscriptions` with `kind: unifiedpush` and the Web Push keys the
     * distributor gave. Returns the subscription as `GET /api/push` lists it.
     */
    fun subscribe(endpoint: String, p256dh: String, auth: String, name: String?): JSONObject {
        val body = JSONObject()
            .put("endpoint", endpoint)
            .put("keys", JSONObject().put("p256dh", p256dh).put("auth", auth))
            .put("kind", "unifiedpush")
        if (!name.isNullOrBlank()) body.put("name", name.take(100))
        return request("POST", body, "subscriptions").optJSONObject("subscription")
            ?: throw PushGatewayException(null, null, "The gateway gave no subscription")
    }

    /**
     * `PATCH /api/push/subscriptions/{id}` with [fields] (`levels`, `quietHours`,
     * `timeZone`, `lockScreen`, `digestAt`) at [revision]. Returns the changed target.
     */
    fun update(id: String, revision: Long, fields: JSONObject): JSONObject {
        val body = JSONObject().put("revision", revision)
        for (key in fields.keys()) body.put(key, fields.get(key))
        return request("PATCH", body, "subscriptions", id).optJSONObject("subscription")
            ?: throw PushGatewayException(null, null, "The gateway gave no subscription")
    }

    /** `DELETE /api/push/subscriptions` by endpoint. */
    fun unsubscribe(endpoint: String) {
        request("DELETE", JSONObject().put("endpoint", endpoint), "subscriptions")
    }

    private fun request(method: String, json: JSONObject?, vararg path: String): JSONObject {
        val token = tokens()?.takeIf { it.isNotEmpty() }
            ?: throw PushGatewayException(401, "unpaired", "This device is not paired")
        val url = gateway.newBuilder().addPathSegments("api/push").apply { path.forEach { addPathSegment(it) } }.build()
        val body: RequestBody? = json?.toString()?.toRequestBody(JSON)
        val call = Request.Builder().url(url).method(method, body)
            .header("Authorization", "Bearer $token")
            .header("Accept", "application/json")
            .build()
        http.newCall(call).execute().use { response ->
            val text = response.body.string()
            val parsed = text.takeIf { it.isNotBlank() }?.let { runCatching { JSONObject(it) }.getOrNull() }
            if (response.isSuccessful) return parsed ?: JSONObject()
            val error = parsed?.optJSONObject("error")
            throw PushGatewayException(
                response.code,
                error?.text("code"),
                error?.text("message") ?: "The gateway answered ${response.code}",
            )
        }
    }

    private companion object {
        val JSON = "application/json".toMediaType()
    }
}
