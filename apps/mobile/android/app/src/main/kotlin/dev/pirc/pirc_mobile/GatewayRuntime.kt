package dev.pirc.pirc_mobile

import android.content.Context
import dev.pirc.android.core.*
import dev.pirc.android.core.timeline.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.UUID
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.ConcurrentHashMap

fun JsonElement?.wire(): Any? = when (this) {
    null, JsonNull -> null
    is JsonObject -> entries.associate { it.key to it.value.wire() }
    is JsonArray -> map { it.wire() }
    is JsonPrimitive -> if (isString) content else booleanOrNull ?: longOrNull ?: doubleOrNull ?: content
}
fun Any?.json(): JsonElement = when (this) {
    null -> JsonNull
    is Map<*, *> -> JsonObject(entries.associate { it.key.toString() to it.value.json() })
    is List<*> -> JsonArray(map { it.json() })
    is Boolean -> JsonPrimitive(this)
    is Number -> JsonPrimitive(this)
    else -> JsonPrimitive(toString())
}
fun SessionState.wire(): Map<String, Any?> = mapOf(
    "session" to PircJson.encodeToJsonElement(Session.serializer(), session).wire(),
    "run" to run?.let { mapOf("id" to it.id, "status" to it.status, "failureReason" to it.failureReason) },
    "runnerStatus" to runnerStatus, "runnerEpoch" to runnerEpoch, "cursor" to cursor,
    "modelId" to selectedModelId, "modelProvider" to selectedModelProvider, "thinking" to thinkingLevel,
    "widgets" to widgets, "statuses" to statuses,
    "queue" to queue.map { mapOf("id" to it.id, "kind" to it.kind, "content" to it.content, "index" to it.index) },
    "interactions" to interactions.map { it.wire() },
    "messages" to messages.map { m -> mapOf(
        "id" to m.id, "role" to m.role, "content" to m.content, "createdAt" to m.createdAt,
        "partial" to m.isPartial, "thinking" to m.thinking, "error" to m.errorMessage,
        "label" to m.label, "systemKind" to m.systemKind,
        "images" to m.images.map { mapOf("mimeType" to it.mimeType, "base64" to it.base64) },
        "tools" to m.tools.map { t -> mapOf("id" to t.id, "name" to t.name, "title" to t.title,
            "status" to t.status, "input" to t.input.wire(), "output" to t.output,
            "diff" to t.diff, "recording" to t.recording,
            "images" to t.images.map { mapOf("mimeType" to it.mimeType, "base64" to it.base64) }) }
    ) }
)
fun Interaction.wire() = mapOf("id" to id, "epoch" to runnerEpoch, "kind" to kind,
    "title" to title, "description" to description, "expiresAt" to expiresAt, "status" to status,
    "multiple" to multiple, "placeholder" to placeholder, "initialValue" to initialValue,
    "options" to options.map { mapOf("value" to it.value, "label" to it.label, "description" to it.description) })

/** Recheck the exact question the user saw against the latest snapshot. */
fun checkedAnswer(before: SessionState, interactionId: String, epoch: String, data: Map<*, *>, now: Long = System.currentTimeMillis()): InteractionAnswer {
    val question = before.interactions.find { it.id == interactionId }
        ?: throw ApiException(409, "stale", "問題已不存在，請重新整理")
    if (question.status != "pending" || question.runnerEpoch != epoch || before.runnerEpoch != epoch ||
        (question.expiresAt != null && question.expiresAt!! <= now)) throw ApiException(409, "stale", "問題已處理或過期")
    return when {
        data["cancelled"] == true -> InteractionAnswer.Cancel
        question.kind == "confirm" -> InteractionAnswer.Confirm(data["confirmed"] as? Boolean ?: throw ApiException(400, "invalid_answer", "請選擇確認或拒絕"))
        question.kind == "select" -> {
            val values = (data["values"] as? List<*>)?.mapNotNull { it as? String }.orEmpty()
            if (values.isEmpty() || values.distinct().size != values.size || (!question.multiple && values.size != 1) || values.any { v -> question.options.none { it.value == v } }) throw ApiException(400, "invalid_answer", "選项已變更，請重新選擇")
            InteractionAnswer.Choices(values)
        }
        question.kind in listOf("input", "editor") -> InteractionAnswer.Text(data["value"] as? String ?: throw ApiException(400, "invalid_answer", "請輸入答案"))
        else -> throw ApiException(400, "invalid_answer", "此問題類型尚不支援")
    }
}

/** Uses the existing Android authentication, HTTP client, reducer and event resumption. */
class GatewayRuntime private constructor(val context: Context) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val local = LocalStore(context)
    private val credentials = KeystoreCredentialStore(context)
    private var activeApi: PircApi? = null
    private var watcher: Job? = null
    private var heartbeats: Job? = null
    private var watched: String? = null
    private val socketTokens = ConcurrentHashMap<String, String>()
    private val heldGenerations = mutableMapOf<String, Long>()
    private val answerLock = Mutex()
    private val commandLock = Mutex()
    private var pendingSnapshot: Job? = null
    private val sockets = mutableMapOf<String, WebSocket>()
    var listener: ((Map<String, Any?>) -> Unit)? = null
    var latest: SessionState? = null
    private val uncertain = context.getSharedPreferences("uncertain_answers", Context.MODE_PRIVATE)

    init { Connectivity.start(context) }
    // A lost POST response is uncertain; HTTP transport must not replay mutations.
    private fun connectedApi(pairing: Pairing) = PircApi(pairing, defaultHttpClient().newBuilder().retryOnConnectionFailure(false).addInterceptor(ReadRecovery()).build())
    suspend fun api(): PircApi = activeApi ?: withContext(Dispatchers.IO) {
        credentials.load()?.let { connectedApi(it) } ?: throw ApiException(401, "unpaired", "請先配對此裝置")
    }.also { activeApi = it }

    suspend fun boot(): Map<String, Any?> {
        val pairing = withContext(Dispatchers.IO) { credentials.load() }
        return mapOf("origin" to pairing?.baseUrl, "clientId" to local.clientId)
    }
    suspend fun pair(link: String): Map<String, Any?> {
        val pairing = PairingLink.parse(link)
        val candidate = connectedApi(pairing)
        candidate.sessions() // Verify before replacing the saved connection.
        unwatch()
        closeSockets()
        val previous = withContext(Dispatchers.IO) { credentials.load() }
        if (previous != pairing) {
            dev.pirc.android.push.PushRegistration.disable(context, activeApi ?: previous?.let { connectedApi(it) })
            local.clearDrafts(); uncertain.edit().clear().commit()
            context.getSharedPreferences("recent_activity", Context.MODE_PRIVATE).edit().clear().apply()
        }
        withContext(Dispatchers.IO) { credentials.save(pairing) }
        activeApi = candidate
        return boot()
    }
    suspend fun unpair() {
        unwatch(); closeSockets()
        dev.pirc.android.push.PushRegistration.disable(context, activeApi)
        withContext(Dispatchers.IO) { credentials.clear() }
        activeApi = null; latest = null; local.clearDrafts(); uncertain.edit().clear().commit()
    }
    fun emit(type: String, data: Any?, sessionId: String? = watched) {
        scope.launch { listener?.invoke(mapOf("type" to type, "sessionId" to sessionId, "data" to data)) }
    }
    suspend fun request(method: String, path: String, body: Any?): Any? = withContext(Dispatchers.IO) {
        require(path.startsWith("/api/") && !path.contains('\\') && !path.contains('#'))
        val api = api()
        val payload = if (method in listOf("GET", "HEAD")) null else body.json().toString().toRequestBody("application/json".toMediaType())
        api.client.newCall(api.request(path).header("Accept", "application/json").method(method, payload).build()).execute().use { response ->
            val text = response.body?.string().orEmpty()
            val json = runCatching { PircJson.parseToJsonElement(text) }.getOrNull()
            if (!response.isSuccessful) throw api.failure(response, text)
            if (response.code == 204) null else json?.wire() ?: throw ApiException(502, "bad_reply", "伺服器回傳的內容不是 JSON，請檢查 gateway 與反向代理")
        }
    }
    suspend fun snapshot(id: String): SessionState = snapshotState(api().snapshot(id))

    fun watch(id: String) {
        unwatch(release = watched != id)
        watched = id
        watcher = scope.launch {
            var attempt = 0
            while (isActive) {
                try {
                    emit("connection", "connecting", id)
                    var state = snapshot(id)
                    latest = state; GatewayNotifications.sync(context,state); emit("snapshot", state.wire(), id)
                    api().events(id, state.cursor).collect { signal ->
                        when (signal) {
                            StreamSignal.Connected -> { attempt = 0; emit("connection", "live", id) }
                            StreamSignal.Reconnecting -> emit("connection", "reconnecting", id)
                            is StreamSignal.Closed -> throw signal.error
                            is StreamSignal.Event -> {
                                val before = state
                                state = state.reduce(signal.envelope)
                                GatewayNotifications.sync(context,state,before)
                                if (state.needsSnapshot) throw Resnapshot()
                                latest = state
                                if (pendingSnapshot?.isActive != true) pendingSnapshot = scope.launch {
                                    delay(32)
                                    if (watched == id) latest?.let { emit("snapshot", it.wire(), id) }
                                }
                            }
                        }
                    }
                } catch (_: Resnapshot) { continue }
                catch (e: CancellationException) { throw e }
                catch (e: Exception) {
                    emit("error", e.message, id)
                    if (e is ApiException && e.status in listOf(401,403,404)) { emit("connection", "stopped", id); break }
                    emit("connection", "reconnecting", id)
                    delay(minOf(20_000L, 750L shl minOf(attempt++, 5)))
                }
            }
        }
        heartbeats = scope.launch {
            while (isActive) {
                runCatching { lease(id, acquire = true) }.onSuccess { emit("control", it, id) }
                delay(10_000)
            }
        }
    }
    fun unwatch(release: Boolean = false) {
        watcher?.cancel(); heartbeats?.cancel(); pendingSnapshot?.cancel()
        watcher = null; heartbeats = null; pendingSnapshot = null
        val previous = watched; watched = null
        if(previous!=null) GatewayNotifications.manager(context).cancel(("progress:$previous").hashCode())
        val oldApi = activeApi
        val generation = heldGenerations.remove(previous)
        // Release only the observed generation, never a lease acquired by a newer watch.
        if (release && previous != null && generation != null && oldApi != null) scope.launch {
            runCatching { oldApi.releaseControl(previous, local.clientId, generation) }
        }
    }
    suspend fun lease(id: String, acquire: Boolean = false, force: Boolean = false): Map<String, Any?> {
        val api = api()
        var lease = api.control(id, local.clientId)
        lease = when {
            force -> api.acquireControl(id, local.clientId, true)
            lease.heldByCurrentClient && lease.generation != null -> api.heartbeatControl(id, local.clientId, lease.generation!!)
            acquire && lease.free -> api.acquireControl(id, local.clientId, false)
            else -> lease
        }
        if (lease.heldByCurrentClient && lease.generation != null) heldGenerations[id] = lease.generation!!
        else heldGenerations.remove(id)
        return mapOf("held" to lease.heldByCurrentClient, "holder" to lease.holderClientId,
            "generation" to lease.generation, "expiresAt" to lease.expiresAt)
    }
    suspend fun generation(id: String): Long {
        val lease = lease(id, acquire = true)
        if (lease["held"] != true) throw ApiException(409, "lost_control", "控制權在其他裝置，請先明確取得控制權")
        return lease["generation"] as Long
    }
    fun unknownCommand(id: String) = uncertain.contains("command:$id")
    fun acknowledgeCommand(id: String) { uncertain.edit().remove("command:$id").commit() }
    suspend fun command(id: String, payload: Map<*, *>, commandId: String): Map<String, Any?> = commandLock.withLock {
        if (unknownCommand(id) && payload["type"] != "stop") throw ApiException(409, "outcome_unknown", "先前送出結果不明，請先檢查對話並確認繼續")
        val api = api()
        val generation = generation(id)
        val key = "command:$id"
        val pendingBefore = uncertain.getString(key, null)
        uncertain.edit().putString(key, commandId).commit()
        try {
            val receipt = api.command(id, local.clientId, generation, commandId, payload.json() as JsonObject)
            if (receipt.status != "outcome_unknown") {
                if (pendingBefore != null) uncertain.edit().putString(key, pendingBefore).commit()
                else uncertain.edit().remove(key).commit()
            }
            mapOf("commandId" to receipt.commandId, "status" to receipt.status, "message" to receipt.message)
        } catch (e: ApiException) {
            if (e.status in 400..499) {
                if (pendingBefore != null) uncertain.edit().putString(key, pendingBefore).commit()
                else uncertain.edit().remove(key).commit()
            }
            throw e
        }
    }
    suspend fun answer(id: String, interactionId: String, epoch: String, data: Map<*, *>): Map<String, Any?> = answerLock.withLock {
        val before = snapshot(id)
        val answer = checkedAnswer(before, interactionId, epoch, data)
        val key = "$id:$interactionId:$epoch"
        if (uncertain.getBoolean(key, false)) throw ApiException(409, "outcome_unknown", "先前回答結果不明，請檢查最新狀態，不可重送")
        val generation = generation(id)
        // Persist before the POST: process death must not turn uncertainty into a retry.
        uncertain.edit().putBoolean(key, true).commit()
        try {
            api().answer(id, interactionId, local.clientId, generation, answer)
            uncertain.edit().remove(key).commit()
        } catch (e: ApiException) {
            if (e.status in 400..499) uncertain.edit().remove(key).commit()
            throw e
        }
        snapshot(id).wire()
    }
    suspend fun openSocket(tag: String, path: String) {
        require(path.startsWith("/api/sessions/") && path.endsWith("/stream"))
        closeSocket(tag)
        val token = UUID.randomUUID().toString()
        socketTokens[tag] = token
        val api = api()
        val socket = api.client.newBuilder().readTimeout(0, java.util.concurrent.TimeUnit.MILLISECONDS)
            .pingInterval(25, java.util.concurrent.TimeUnit.SECONDS).build()
            .newWebSocket(api.request(path).build(), object: WebSocketListener() {
                override fun onMessage(ws: WebSocket, text: String) { if (socketTokens[tag] != token) return; emit("socket", mapOf("tag" to tag, "frame" to runCatching { PircJson.parseToJsonElement(text).wire() }.getOrNull())) }
                override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) { if (socketTokens[tag] != token) return; emit("socketClosed", mapOf("tag" to tag, "code" to response?.code, "message" to t.message)) }
                override fun onClosing(ws: WebSocket, code: Int, reason: String) { ws.close(1000, null); if (socketTokens[tag] != token) return; emit("socketClosed", mapOf("tag" to tag, "code" to code, "message" to reason)) }
            })
        sockets[tag] = socket
    }
    fun sendSocket(tag: String, data: Map<*, *>) { check(sockets[tag]?.send(data.json().toString()) == true) { "Socket 已斷線" } }
    fun closeSocket(tag: String) { socketTokens.remove(tag); sockets.remove(tag)?.cancel() }
    fun closeSockets() { socketTokens.clear(); sockets.values.forEach { it.cancel() }; sockets.clear() }
    private class Resnapshot: Exception()
    companion object {
        @Volatile private var instance: GatewayRuntime? = null
        fun get(context: Context) = instance ?: synchronized(this) {
            instance ?: GatewayRuntime(context.applicationContext).also { instance = it }
        }
    }
}
