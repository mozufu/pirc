package dev.pirc.android.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import dev.pirc.android.core.timeline.get
import dev.pirc.android.core.timeline.number
import dev.pirc.android.core.timeline.text
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

/** A failed gateway request. `unauthorized` means the device token is dead: pair again. */
class ApiException(val status: Int, val code: String?, message: String, cause: Throwable? = null) : IOException(message, cause) {
    val unauthorized get() = status == 401
}

/**
 * Read a successful reply. Anything but the JSON this client expects (a proxy's
 * HTML page, a truncated body, an older gateway) becomes an [ApiException] like
 * any other failed request, instead of an unchecked exception that would end the app.
 */
internal inline fun <T> readingReply(status: Int = 200, read: () -> T): T = try {
    read()
} catch (error: IOException) {
    throw error
} catch (error: kotlin.coroutines.cancellation.CancellationException) {
    throw error
} catch (error: RuntimeException) {
    throw ApiException(status, "bad_reply", "The gateway sent a reply this app cannot read; check the address points at pirc.", error)
}

/** Why the gateway refused this phone's token, as shown to the user. */
internal fun unauthorizedMessage(reason: String?): String {
    val why = reason?.trim()?.trimEnd('.')?.takeIf { it.isNotEmpty() }?.replaceFirstChar { it.uppercase() }
        ?: "This phone's device token is invalid, expired or revoked"
    return "$why. Pair this phone again."
}

internal fun String.urlSegment(): String = URLEncoder.encode(this, Charsets.UTF_8).replace("+", "%20")

private val JSON = "application/json".toMediaType()

/** Request-shape marker the Gateway requires on state-changing requests. Page content can never set it. */
internal const val REQUEST_SHAPE_HEADER = "X-Pirc-Request"

/** Error code of a state-changing request the gateway refused for its shape (HTTP 415). */
internal const val REQUEST_SHAPE_REQUIRED = "request_shape_required"

val PircJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
}

fun defaultHttpClient(): OkHttpClient = OkHttpClient.Builder()
    .connectTimeout(15, TimeUnit.SECONDS)
    .readTimeout(30, TimeUnit.SECONDS)
    // Image uploads (up to 8 MiB) over mobile data take longer than the default 10 s.
    .writeTimeout(60, TimeUnit.SECONDS)
    // Tokens must never follow a redirect to another origin.
    .followRedirects(false)
    .followSslRedirects(false)
    .build()

/** The gateway's browser API, authenticated with this phone's device token. Open for test fakes. */
open class PircApi(val pairing: Pairing, internal val client: OkHttpClient = defaultHttpClient()) {

    open suspend fun sessions(): List<Session> = get<SessionsResponse>("/api/sessions").sessions

    open suspend fun workspaces(): List<Workspace> = get<WorkspacesResponse>("/api/workspaces").workspaces

    open suspend fun nodes(): List<NodeSummary> = get<NodesResponse>("/api/nodes").nodes

    /** The raw snapshot; see `snapshotState` in `core.timeline`. */
    open suspend fun snapshot(sessionId: String): JsonElement =
        get<JsonElement>("/api/sessions/${sessionId.urlSegment()}/snapshot")

    /** Read configured bindings directly from Gateway, including while Node is offline. */
    open suspend fun environment(sessionId: String): ConversationEnvironment = readingReply {
        get<ConversationEnvironment>("/api/sessions/${sessionId.urlSegment()}/environment").also { it.validateSession(sessionId) }
    }

    /** The live event stream of one session; see [EventStream]. */
    open fun events(sessionId: String, cursor: String?) = EventStream(this).open(sessionId, cursor)

    // ---- sessions and workspaces ----

    /** A new session in [workspaceId]; the agent titles it from the first message. */
    open suspend fun createSession(workspaceId: String): Session =
        decodeSession(send("POST", "/api/sessions", buildJsonObject { put("workspaceId", workspaceId) }))

    /** Rename, pin or settle a session (any combination). */
    open suspend fun updateSession(sessionId: String, name: String? = null, pinned: Boolean? = null, settled: Boolean? = null): Session =
        decodeSession(
            send("PATCH", session(sessionId), buildJsonObject {
                name?.let { put("name", it) }
                pinned?.let { put("pinned", it) }
                settled?.let { put("settled", it) }
            }),
        )

    /** Register a folder on an online node; it must exist inside that account's home. */
    open suspend fun createWorkspace(nodeId: String, path: String, displayName: String): Workspace {
        val reply = send("POST", "/api/workspaces", buildJsonObject {
            put("nodeId", nodeId)
            put("path", path)
            put("displayName", displayName)
        })
        return readingReply { PircJson.decodeFromJsonElement(Workspace.serializer(), reply["workspace"] ?: error("no workspace in the reply")) }
    }

    private fun decodeSession(reply: JsonElement?) = readingReply {
        PircJson.decodeFromJsonElement(Session.serializer(), reply["session"] ?: error("no session in the reply"))
    }

    // ---- workspace files (read-only, confined to the session's workspace) ----

    open suspend fun files(sessionId: String, path: String): DirListing =
        get<DirListing>("${session(sessionId)}/files?path=${path.urlSegment()}")

    open suspend fun file(sessionId: String, path: String): FileContent =
        get<FileContent>("${session(sessionId)}/files/content?path=${path.urlSegment()}")

    // ---- side panels ----

    open suspend fun gitStatus(sessionId: String): GitStatus = get("${session(sessionId)}/git/status")

    open suspend fun gitDiff(sessionId: String, path: String, staged: Boolean, untracked: Boolean): Diff =
        get("${session(sessionId)}/git/diff?path=${path.urlSegment()}" + (if (staged) "&staged=1" else "") + (if (untracked) "&untracked=1" else ""))

    open suspend fun gitLog(sessionId: String, skip: Int, limit: Int = 50): CommitPage =
        get("${session(sessionId)}/git/log?skip=$skip&limit=$limit")

    open suspend fun gitShow(sessionId: String, sha: String): CommitDetail =
        get("${session(sessionId)}/git/commits/${sha.urlSegment()}")

    open suspend fun panelState(sessionId: String): PanelState = get("${session(sessionId)}/panel/state")

    open suspend fun backgroundOutput(sessionId: String, taskId: String, lines: Int = 400): BackgroundOutput =
        get("${session(sessionId)}/panel/background/${taskId.urlSegment()}?lines=$lines")

    /** Needs the control lease; returns once the stop is requested (status `stopping`). */
    open suspend fun stopBackground(sessionId: String, taskId: String, clientId: String, generation: Long): BackgroundTask {
        val reply = send("POST", "${session(sessionId)}/panel/background/${taskId.urlSegment()}/stop", held(clientId, generation))
        return readingReply { PircJson.decodeFromJsonElement(TaskResponse.serializer(), reply ?: error("empty reply")).task }
    }

    open suspend fun terminals(sessionId: String): List<TerminalInfo> = get<TerminalsResponse>("${session(sessionId)}/terminals").terminals

    /** Needs the control lease. */
    open suspend fun createTerminal(sessionId: String, clientId: String, generation: Long, cols: Int, rows: Int): TerminalInfo {
        val reply = send("POST", "${session(sessionId)}/terminals", buildJsonObject {
            put("clientId", clientId)
            put("generation", generation)
            put("cols", cols)
            put("rows", rows)
        })
        return readingReply { PircJson.decodeFromJsonElement(TerminalResponse.serializer(), reply ?: error("empty reply")).terminal }
    }

    open suspend fun closeTerminal(sessionId: String, terminalId: String, clientId: String, generation: Long) {
        send("POST", "${session(sessionId)}/terminals/${terminalId.urlSegment()}/close", held(clientId, generation))
    }

    /** The terminal's WebSocket request (bearer-authenticated, so the app owns the socket). */
    internal fun terminalRequest(sessionId: String, terminalId: String) =
        request("${session(sessionId)}/terminals/${terminalId.urlSegment()}/stream").build()

    /** The session's browser live view (docs/guides/browser.md), bearer-authenticated like terminals. */
    internal fun browserRequest(sessionId: String) =
        request("${session(sessionId)}/browser/stream").build()

    /**
     * Save a browser recording (`.pirc/recordings/<name>.webm`) to [dest] for the
     * system video player; it needs the bearer token, so it is fetched here.
     */
    open suspend fun downloadRecording(sessionId: String, path: String, dest: java.io.File) = withContext(Dispatchers.IO) {
        val url = "${session(sessionId)}/browser/recording?path=${path.urlSegment()}"
        client.newCall(request(url).build()).execute().use { response ->
            if (!response.isSuccessful) throw failure(response, response.body.string())
            dest.outputStream().use { out -> response.body.byteStream().copyTo(out) }
        }
    }

    // ---- acting on a session (needs the control lease) ----

    open suspend fun models(sessionId: String): List<ModelOption> =
        get<ModelsResponse>("/api/models?sessionId=${sessionId.urlSegment()}").models.map { it.option() }

    open suspend fun control(sessionId: String, clientId: String): ControlLease =
        ControlLease.from(send("GET", "${session(sessionId)}/control"), clientId)

    /** Without [force], the node refuses while another client holds a live lease (409). */
    open suspend fun acquireControl(sessionId: String, clientId: String, force: Boolean): ControlLease = ControlLease.from(
        send("POST", "${session(sessionId)}/control/acquire", buildJsonObject {
            put("clientId", clientId)
            put("force", force)
        }),
        clientId,
    )

    open suspend fun heartbeatControl(sessionId: String, clientId: String, generation: Long): ControlLease = ControlLease.from(
        send("POST", "${session(sessionId)}/control/heartbeat", held(clientId, generation)),
        clientId,
    )

    open suspend fun releaseControl(sessionId: String, clientId: String, generation: Long) {
        send("POST", "${session(sessionId)}/control/release", held(clientId, generation))
    }

    /**
     * Send one command. A command the node did not accept still comes back as a
     * receipt (with its reason), so only transport and lease errors throw.
     */
    open suspend fun command(sessionId: String, clientId: String, generation: Long, commandId: String, payload: JsonObject, expectedBinding: ConversationBinding? = null): CommandReceipt {
        val body = buildJsonObject {
            put("commandId", commandId)
            put("clientId", clientId)
            put("generation", generation)
            put("payload", payload)
            expectedBinding?.let { put("expectedBinding", PircJson.encodeToJsonElement(ConversationBinding.serializer(), it)) }
        }
        val reply = send("POST", "${session(sessionId)}/commands", body, acceptBody = { it["command"] != null })
        val command = reply["command"]
        return CommandReceipt(
            commandId = command["id"].text ?: commandId,
            status = command["status"].text ?: "outcome_unknown",
            message = command["error"].text,
        )
    }

    /**
     * A null [generation] answers without the control lease; the gateway accepts
     * that only for relayed (`relay.`) delegation approvals.
     */
    open suspend fun answer(sessionId: String, interactionId: String, clientId: String, generation: Long?, answer: InteractionAnswer) {
        send(
            "POST",
            "${session(sessionId)}/interactions/${interactionId.urlSegment()}/answer",
            buildJsonObject {
                put("clientId", clientId)
                if (generation != null) put("generation", generation)
                put("answer", answer.rpc())
            },
        )
    }

    /** Stop a delegation's run; no lease. 409 when another device controls it or nothing runs. */
    open suspend fun stopDelegation(delegationId: String): String? =
        send("POST", "/api/delegations/${delegationId.urlSegment()}/stop", buildJsonObject {})["status"].text

    /**
     * Store a file on the session's node. Images ride in the model's context;
     * anything else is copied into the workspace for the agent's file tools —
     * [filename] lets the node tell them apart and name the copy.
     */
    open suspend fun upload(sessionId: String, bytes: ByteArray, mimeType: String, filename: String? = null): Upload {
        val query = filename?.let { "?filename=${it.urlSegment()}" } ?: ""
        val reply = send("POST", "${session(sessionId)}/uploads$query", bytes.toRequestBody(mimeType.toMediaType()))
        val upload = reply["upload"]
        return readingReply {
            Upload(
                upload["id"].text ?: error("upload without an id"),
                upload["mimeType"].text ?: mimeType,
                upload["byteSize"].number ?: bytes.size.toLong(),
                upload["kind"].text ?: "image",
            )
        }
    }

    // ---- push notifications (docs/guides/schedules.md) ----

    open suspend fun pushInfo(): PushInfo = get("/api/push")

    /** This phone's UnifiedPush endpoint and Web Push keys; it goes with the device token. */
    open suspend fun subscribePush(endpoint: String, p256dh: String, auth: String, name: String): PushPlace {
        val reply = send("POST", "/api/push/subscriptions", buildJsonObject {
            put("endpoint", endpoint)
            put("keys", buildJsonObject {
                put("p256dh", p256dh)
                put("auth", auth)
            })
            put("kind", "unifiedpush")
            put("name", name)
        })
        return readingReply { PircJson.decodeFromJsonElement(PushSubscribed.serializer(), reply ?: error("empty reply")).subscription }
    }

    open suspend fun unsubscribePush(endpoint: String? = null, id: String? = null) {
        send("DELETE", "/api/push/subscriptions", buildJsonObject {
            endpoint?.let { put("endpoint", it) }
            id?.let { put("id", it) }
        })
    }

    /** A test notification to every place; how many took it. */
    open suspend fun testPush(): Int =
        readingReply { PircJson.decodeFromJsonElement(PushTested.serializer(), send("POST", "/api/push/test", buildJsonObject {}) ?: error("empty reply")).delivered }

    // ---- schedules (docs/guides/schedules.md) ----

    /** Every model the gateway offers, for a schedule's own choice. */
    open suspend fun allModels(): List<ModelOption> = get<ModelsResponse>("/api/models").models.map { it.option() }

    open suspend fun schedules(): List<Schedule> = get<SchedulesResponse>("/api/schedules").schedules

    open suspend fun schedule(id: String): ScheduleDetail = get("/api/schedules/${id.urlSegment()}")

    /** Project files are raw bytes, including JSON documents; no attachment/session is created. */
    open suspend fun uploadProjectFile(workspaceId: String, filename: String, body: RequestBody): JsonObject = readingReply {
        send("POST", "/api/workspaces/${workspaceId.urlSegment()}/files?filename=${filename.urlSegment()}", body)
            as? JsonObject ?: error("empty project file reply")
    }

    /** The user's own schedules need no approval (only an agent's do). */
    open suspend fun createSchedule(input: ScheduleInput): Schedule =
        decodeSchedule(send("POST", "/api/schedules", scheduleBody(input)))

    open suspend fun updateSchedule(id: String, input: ScheduleInput): Schedule =
        decodeSchedule(send("PATCH", "/api/schedules/${id.urlSegment()}", scheduleBody(input)))

    /** Pause (`paused`) or resume (`active`); fire times while paused are not made up. */
    open suspend fun setScheduleStatus(id: String, status: String): Schedule =
        decodeSchedule(send("PATCH", "/api/schedules/${id.urlSegment()}", buildJsonObject { put("status", status) }))

    open suspend fun deleteSchedule(id: String) {
        send("DELETE", "/api/schedules/${id.urlSegment()}")
    }

    /** Run it now, or allow the missed run [runId]. */
    open suspend fun runSchedule(id: String, runId: String? = null): ScheduleRun =
        decodeRun(send("POST", "/api/schedules/${id.urlSegment()}/run", buildJsonObject { runId?.let { put("runId", it) } }))

    open suspend fun dismissRun(id: String, runId: String): ScheduleRun =
        decodeRun(send("POST", "/api/schedules/${id.urlSegment()}/runs/${runId.urlSegment()}/dismiss", buildJsonObject {}))

    // ---- the assistant's memory (docs/architecture/assistant-memory.md): proposals only ----

    open suspend fun memory(): MemoryView = get("/api/memory")

    /** [targetRevision]: the version of the changed entry the user was shown. */
    open suspend fun approveProposal(id: String, targetRevision: Int? = null): MemoryView =
        decodeMemory(send("POST", "/api/memory/proposals/${id.urlSegment()}/approve", buildJsonObject { targetRevision?.let { put("targetRevision", it) } }))

    open suspend fun rejectProposal(id: String): MemoryView =
        decodeMemory(send("POST", "/api/memory/proposals/${id.urlSegment()}/reject", buildJsonObject {}))

    private fun decodeMemory(reply: JsonElement?) = readingReply {
        reply?.let { PircJson.decodeFromJsonElement(MemoryView.serializer(), it) } ?: MemoryView()
    }

    private fun scheduleBody(input: ScheduleInput) = buildJsonObject {
        put("workspaceId", input.workspaceId)
        put("title", input.title)
        put("prompt", input.prompt)
        put("timezone", input.timezone)
        input.cron?.let { put("cron", it) }
        input.at?.let { put("at", it) }
        if (input.model != null) put("model", buildJsonObject {
            put("provider", input.model.provider)
            put("id", input.model.id)
        }) else put("model", JsonNull)
        if (input.thinking != null) put("thinking", input.thinking) else put("thinking", JsonNull)
        put("notify", input.notify)
    }

    private fun decodeSchedule(reply: JsonElement?) = readingReply {
        PircJson.decodeFromJsonElement(ScheduleResponse.serializer(), reply ?: error("empty reply")).schedule
    }

    private fun decodeRun(reply: JsonElement?) = readingReply {
        PircJson.decodeFromJsonElement(RunResponse.serializer(), reply ?: error("empty reply")).run
    }

    private fun session(sessionId: String) = "/api/sessions/${sessionId.urlSegment()}"

    private fun held(clientId: String, generation: Long) = buildJsonObject {
        put("clientId", clientId)
        put("generation", generation)
    }

    private suspend fun send(method: String, path: String, json: JsonObject, acceptBody: (JsonElement?) -> Boolean = { false }): JsonElement? =
        send(method, path, PircJson.encodeToString(JsonObject.serializer(), json).toRequestBody(JSON), acceptBody)

    /** A JSON request; the reply body, or null for 204. */
    private suspend fun send(
        method: String,
        path: String,
        body: RequestBody? = null,
        acceptBody: (JsonElement?) -> Boolean = { false },
    ): JsonElement? = withContext(Dispatchers.IO) {
        val request = request(path).header("Accept", "application/json").method(method, body).build()
        client.newCall(request).execute().use { response ->
            val text = response.body.string()
            val parsed = runCatching { PircJson.parseToJsonElement(text) }.getOrNull()
            if (!response.isSuccessful && !(response.code != 401 && acceptBody(parsed))) throw failure(response, text)
            if (response.code == 204 || text.isBlank()) null else parsed
        }
    }

    private data class ManagementGrant(val token: String, val expiresAt: Long, val deadline: Long, val capabilities: Set<String>)
    @Volatile private var managementGrant: ManagementGrant? = null
    internal var managementClock: () -> Long = { System.nanoTime() / 1_000_000 }

    /** Temporary consent stays in this API instance; never persists with pairing. */
    @Synchronized internal fun installManagementGrant(token: String, expiresAt: Long, serverNow: Long, capabilities: Set<String>) {
        require(token.matches(Regex("^[A-Za-z0-9_-]{32,160}$")))
        require(capabilities.isNotEmpty() && capabilities.all { it == "providers" || it == "devices" })
        val remaining = expiresAt - serverNow
        require(remaining in 1..900_000)
        managementGrant = ManagementGrant(token, expiresAt, managementClock() + remaining, capabilities)
    }
    @Synchronized internal fun clearManagementGrant() { managementGrant = null }
    @Synchronized internal fun managementStatus(): Map<String, Any> {
        val grant = managementGrant ?: return mapOf("active" to false)
        val remaining = grant.deadline - managementClock()
        if (remaining <= 0) { managementGrant = null; return mapOf("active" to false) }
        return mapOf("active" to true, "expiresAt" to grant.expiresAt, "remainingMs" to remaining, "capabilities" to grant.capabilities.toList())
    }
    internal fun request(path: String): Request.Builder {
        val builder = Request.Builder().url(pairing.baseUrl + path)
            .header("Authorization", "Bearer ${pairing.token}")
            // Marks this as the app's own client; every Gateway request the app makes is built here.
            .header(REQUEST_SHAPE_HEADER, "1")
        val route = builder.build().url.encodedPath
        val capability = when {
            Regex("^/api/(providers|provider-auth)(/|$)").containsMatchIn(route) -> "providers"
            Regex("^/api/devices(/|$)").containsMatchIn(route) -> "devices"
            else -> null
        }
        synchronized(this) {
            val grant = managementGrant
            if (grant != null && grant.deadline > managementClock() && capability in grant.capabilities) {
                builder.header("X-Pirc-Management", grant.token)
            } else if (grant != null && grant.deadline <= managementClock()) managementGrant = null
        }
        return builder
    }

    private suspend inline fun <reified T> get(path: String): T = withContext(Dispatchers.IO) {
        val request = request(path).header("Accept", "application/json").build()
        client.newCall(request).execute().use { response ->
            val body = response.body.string()
            if (!response.isSuccessful) throw failure(response, body)
            readingReply(response.code) { PircJson.decodeFromString<T>(body) }
        }
    }

    internal fun failure(response: Response, body: String): ApiException {
        val detail = runCatching { PircJson.decodeFromString<ErrorBody>(body).error }.getOrNull()
        if (response.code == 401 || (response.code == 403 && detail?.code in setOf("management_required", "management_expired", "management_revoked"))) clearManagementGrant()
        val message = when {
            // The gateway says whether the token expired or was revoked.
            response.code == 401 -> unauthorizedMessage(detail?.message)
            response.isRedirect -> "The gateway redirected the request; check the proxy routes device tokens to pirc."
            // The gateway needs a request shape this build does not send; only an update fixes that.
            response.code == 415 && detail?.code == REQUEST_SHAPE_REQUIRED ->
                "This version of the app is out of date. Update the app, then try again."
            else -> detail?.message ?: "Request failed (${response.code})"
        }
        return ApiException(response.code, detail?.code, message)
    }
}
