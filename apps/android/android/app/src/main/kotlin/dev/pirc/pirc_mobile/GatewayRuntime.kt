package dev.pirc.pirc_mobile

import android.content.Context
import dev.pirc.android.core.*
import dev.pirc.android.core.timeline.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
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
    "approvalMode" to approvalMode, "defaultApprovalMode" to defaultApprovalMode,
    "widgets" to widgets, "statuses" to statuses,
    "sandbox" to sandbox?.let { mapOf("active" to it.active, "reason" to it.reason) },
    "queue" to queue.map { mapOf("id" to it.id, "kind" to it.kind, "content" to it.content, "index" to it.index) },
    "interactions" to interactions.map { it.wire() },
    "delegations" to delegations.map { it.wire() },
    "messages" to messages.map { m -> mapOf(
        "id" to m.id, "role" to m.role, "content" to m.content, "createdAt" to m.createdAt,
        "entryId" to m.entryId,
        "branches" to m.branches.map { mapOf("entryId" to it.entryId, "text" to it.text, "selected" to it.selected) },
        "partial" to m.isPartial, "thinking" to m.thinking, "error" to m.errorMessage,
        "label" to m.label, "systemKind" to m.systemKind, "level" to m.level, "meta" to m.meta,
        "thinkingRedacted" to m.thinkingRedacted, "stopReason" to m.stopReason, "model" to m.model,
        "images" to m.images.map { mapOf("mimeType" to it.mimeType, "base64" to it.base64) },
        "tools" to m.tools.map { it.wire() }
    ) }
)
private fun ToolCall.wire(): Map<String, Any?> = mapOf(
    "id" to id, "name" to name, "title" to title, "status" to status,
    "input" to input.wire(), "output" to output, "diff" to diff,
    "recording" to recording, "startedAt" to startedAt, "endedAt" to endedAt,
    "images" to images.map { mapOf("mimeType" to it.mimeType, "base64" to it.base64) },
    "operations" to operations.map { it.wire() },
)
fun Interaction.wire() = mapOf("id" to id, "epoch" to runnerEpoch, "kind" to kind,
    "title" to title, "description" to description, "expiresAt" to expiresAt, "status" to status,
    "toolCallId" to toolCallId,
    "multiple" to multiple, "placeholder" to placeholder, "initialValue" to initialValue,
    "confirmLabel" to confirmLabel, "cancelLabel" to cancelLabel, "modelChoice" to modelChoice.wire(), "language" to language,
    "userRequestChoice" to userRequestChoice?.let { mapOf("label" to it.label, "checked" to it.checked) },
    "options" to options.map { mapOf("value" to it.value, "label" to it.label, "description" to it.description) },
    "relayed" to relayed?.let { mapOf("sessionId" to it.sessionId, "sessionName" to it.sessionName,
        "workspace" to it.workspace, "delegationId" to it.delegationId) })
fun ChatDelegation.wire() = mapOf("id" to id, "title" to title, "workspace" to workspace, "status" to status,
    "dispatch" to dispatch, "targetSessionId" to targetSessionId)

/**
 * The control generation an answer must carry, or null for a relayed (`relay.`)
 * delegation approval: the gateway answers those without the chat's lease, so
 * acquiring it would only take control away from another device.
 */
suspend fun answerGeneration(interactionId: String, acquire: suspend () -> Long): Long? =
    if (isRelayedInteraction(interactionId)) null else acquire()

/** Recheck the exact question against a fresh snapshot. The session cursor epoch
 * belongs to the daemon stream and may differ from the node interaction epoch.
 * The answer endpoint validates the active runner and control generation. */
fun checkedAnswer(before: SessionState, interactionId: String, epoch: String, data: Map<*, *>, now: Long = System.currentTimeMillis()): InteractionAnswer {
    val question = before.interactions.find { it.id == interactionId }
        ?: throw ApiException(409, "stale", NativeI18n.text("問題已不存在，請重新整理"))
    if (question.status != "pending" || question.runnerEpoch != epoch ||
        (question.expiresAt != null && question.expiresAt!! <= now)) throw ApiException(409, "stale", NativeI18n.text("問題已處理或過期"))
    return when {
        data["cancelled"] == true -> InteractionAnswer.Cancel
        question.kind == "confirm" -> {
            val confirmed = data["confirmed"] as? Boolean ?: throw ApiException(400, "invalid_answer", NativeI18n.text("請選擇確認或拒絕"))
            val choice = if (confirmed && question.modelChoice != null && (data.containsKey("model") || data.containsKey("thinking"))) {
                val model = data["model"]
                if (model != null && (model !is Map<*, *> || model["provider"] !is String || model["id"] !is String))
                    throw ApiException(400, "invalid_answer", NativeI18n.text("Invalid model choice"))
                val thinking = data["thinking"]
                if (thinking != null && thinking !in listOf("off", "minimal", "low", "medium", "high", "xhigh", "max"))
                    throw ApiException(400, "invalid_answer", NativeI18n.text("Invalid thinking choice"))
                buildJsonObject { put("model", model.json()); put("thinking", thinking.json()) }
            } else null
            val asUserRequest = confirmed && question.userRequestChoice != null && data["asUserRequest"] == true
            InteractionAnswer.Confirm(
                confirmed,
                choice,
                asUserRequest,
                hasUserRequestChoice = question.userRequestChoice != null,
            )
        }
        question.kind == "select" -> {
            val values = (data["values"] as? List<*>)?.mapNotNull { it as? String }.orEmpty()
            if (values.isEmpty() || values.distinct().size != values.size || (!question.multiple && values.size != 1) || values.any { v -> question.options.none { it.value == v } }) throw ApiException(400, "invalid_answer", NativeI18n.text("選项已變更，請重新選擇"))
            InteractionAnswer.Choices(values)
        }
        question.kind in listOf("input", "editor") -> InteractionAnswer.Text(data["value"] as? String ?: throw ApiException(400, "invalid_answer", NativeI18n.text("請輸入答案")))
        else -> throw ApiException(400, "invalid_answer", NativeI18n.text("此問題類型尚不支援"))
    }
}

data class AnswerReconciliation(val pending: Boolean, val interaction: Interaction?)

/** Resolve an uncertain answer only against the exact question in this session snapshot. */
fun answerReconciliation(
    before: SessionState,
    sessionId: String,
    interactionId: String,
    epoch: String,
    now: Long = System.currentTimeMillis(),
): AnswerReconciliation {
    if (before.session.id != sessionId)
        throw ApiException(409, "session_changed", NativeI18n.text("對話已變更，請重新檢查問題"))
    val question = before.interactions.firstOrNull {
        it.id == interactionId && it.runnerEpoch == epoch
    }
    val pending = question != null && question.status == "pending" &&
        (question.expiresAt == null || question.expiresAt > now)
    return AnswerReconciliation(pending, question.takeIf { pending })
}

fun requirePairingStamp(expected: String?, actual: String?) {
    if (expected.isNullOrBlank() || expected != actual)
        throw ApiException(409, "account_changed", NativeI18n.text("配對帳戶已變更，請重新檢查問題"))
}

/** Uses the existing Android authentication, HTTP client, reducer and event resumption. */
class GatewayRuntime private constructor(val context: Context) {
    internal data class HtmlMediaAccess(
        val pairing: Pairing,
        val pairingStamp: String,
        val contextLease: ContextRegistry.Lease,
        val cookies: NativeDocumentCookies?,
    )

    internal data class HtmlMediaResource(
        val bytes: ByteArray,
        val mimeType: String,
        val finalUrl: String,
        val headersRelevant: Map<String, String>,
    )

    private data class ScriptResourceAccess(
        val pairing: Pairing?,
        val pairingStamp: String?,
        val contextLease: ContextRegistry.Lease,
        val cookies: NativeDocumentCookies?,
    )

    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val local = LocalStore(context)
    private val credentials = KeystoreCredentialStore(context)
    private val documentCookies = NativeDocumentCookieStore(context)
    private val documentStorageStore = NativeDocumentStorageStore(context)
    private val documentStorage = NativeDocumentStorageCoordinator(documentStorageStore) {
        emitAccount("documentStorageChanged", it)
    }
    private var activeApi: PircApi? = null
    private var managementSession: Pair<PircApi, NativeManagementSession>? = null
    private val managementLock = Mutex()
    private suspend fun management(): NativeManagementSession = managementLock.withLock {
        val current = api()
        if (managementSession?.first !== current) {
            val stamp = ensurePairingStamp()
            managementSession = current to NativeManagementSession(current,
                { method, path, body -> requestWithApi(current, method, path, body) },
                { validatePairingStamp(stamp); if (activeApi !== current) throw ApiException(409, "account_changed", NativeI18n.text("配對已變更，請重試")) },
            )
        }
        managementSession!!.second
    }
    private fun retireManagement() {
        activeApi?.clearManagementGrant()
        val retired = managementSession?.second
        managementSession = null
        if (retired != null) scope.launch {
            try { withTimeout(5_000) { retired.abandon() } }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: java.io.IOException) { /* Offline cleanup expires at the gateway; local access is already closed. */ }
        }
    }
    suspend fun managementStatus() = management().status()
    suspend fun managementBegin(capabilities: List<String>) = management().begin(capabilities)
    suspend fun managementCheck() = management().check()
    suspend fun managementCancel() = management().cancel()
    suspend fun managementUrl() = management().url()
    private data class SessionWatchState(
        val sessionId: String,
        var latest: SessionState? = null,
        var connection: String = "connecting",
        var watcher: Job? = null,
        var heartbeats: Job? = null,
        var heartbeatWake: Channel<Unit>? = null,
        var pendingSnapshot: Job? = null,
        val composerSettings: SessionComposerSettings = SessionComposerSettings(),
    )
    private data class SocketKey(val contextId: String, val tag: String)
    private val contexts = ContextRegistry()
    /** The only issuer of app-initiated request handles; revoked whenever the account scope changes. */
    private val appRequests = AppRequestAuthority()
    private val watchHub = SessionWatchHub()
    private val sessionWatches = mutableMapOf<String, SessionWatchState>()
    private var watched: String? = null
    private val socketTokens = ConcurrentHashMap<SocketKey, String>()
    private val heldGenerations = mutableMapOf<String, Long>()
    private val answerLock = Mutex()
    private val commandLock = Mutex()
    private val stopCommandLock = Mutex()
    private val sockets = ConcurrentHashMap<SocketKey, WebSocket>()
    var listener: ((Map<String, Any?>) -> Unit)? = null
    var latest: SessionState? = null
    private val uncertain = context.getSharedPreferences("uncertain_answers", Context.MODE_PRIVATE)
    private val pairingIdentity = context.getSharedPreferences("pairing_identity", Context.MODE_PRIVATE)

    init {
        // One process-scoped collector belongs to this runtime singleton, not to
        // each EventChannel subscription. A fresh Flutter listener receives a
        // future network regain without accumulating collectors across engines.
        scope.launch {
            Connectivity.regained.collect {
                emitAccount("networkAvailable", true)
            }
        }
        Connectivity.start(context)
    }
    // A lost POST response is uncertain; HTTP transport must not replay mutations.
    private fun connectedApi(pairing: Pairing) = PircApi(pairing, defaultHttpClient().newBuilder().retryOnConnectionFailure(false).addInterceptor(ReadRecovery()).build())
    private fun rotatePairingStamp(): String {
        appRequests.revokeAll()
        val stamp = UUID.randomUUID().toString()
        if (!pairingIdentity.edit().putString("stamp", stamp).commit())
            throw ApiException(503, "account_changed", NativeI18n.text("無法保存配對狀態，請稍後再試"))
        return stamp
    }
    private fun ensurePairingStamp(): String =
        pairingIdentity.getString("stamp", null) ?: rotatePairingStamp()
    private suspend fun validatePairingStamp(expected: String) {
        val pairing = withContext(Dispatchers.IO) { credentials.load() }
        requirePairingStamp(expected, if (pairing == null) null else ensurePairingStamp())
    }
    suspend fun api(): PircApi = activeApi ?: withContext(Dispatchers.IO) {
        credentials.load()?.let { connectedApi(it) } ?: throw ApiException(401, "unpaired", NativeI18n.text("請先配對此裝置"))
    }.also { activeApi = it }

    suspend fun boot(): Map<String, Any?> = answerLock.withLock {
        val pairing = withContext(Dispatchers.IO) { credentials.load() }
        val stamp = pairing?.let { ensurePairingStamp() }
        withContext(Dispatchers.IO) { documentCookies.bind(stamp); documentStorage.bind(stamp) }
        if (contexts.currentPairingStamp() != stamp) {
            closeAllContexts(releaseLeases = true)
            contexts.bindPairingStamp(stamp)
        }
        mapOf(
            "origin" to pairing?.baseUrl,
            "clientId" to local.clientId,
            "pairingStamp" to stamp,
            "documentStorage" to true,
            "documentStylesheets" to true,
        )
    }
    suspend fun openContext(contextId: String, pairingStamp: String): Map<String, Any?> = answerLock.withLock {
        val pairing = withContext(Dispatchers.IO) { credentials.load() }
            ?: throw ApiException(401, "unpaired", NativeI18n.text("請先配對此裝置"))
        val currentStamp = ensurePairingStamp()
        requirePairingStamp(pairingStamp, currentStamp)
        if (contexts.currentPairingStamp() != currentStamp) {
            closeAllContexts(releaseLeases = true)
            contexts.bindPairingStamp(currentStamp)
        }
        val lease = try {
            contexts.openContext(contextId, currentStamp)
        } catch (e: ContextRegistryException) {
            throw ApiException(409, "context_expired", e.message ?: NativeI18n.text("此原生視窗已關閉"))
        } catch (e: IllegalStateException) {
            throw ApiException(409, "context_invalid", e.message ?: NativeI18n.text("無法開啟原生視窗"))
        }
        mapOf(
            "contextId" to lease.contextId,
            "contextEpoch" to lease.generation,
            "origin" to pairing.baseUrl,
            "clientId" to local.clientId,
            "pairingStamp" to currentStamp,
        )
    }
    /** Local checks must not decrypt credentials or perform network I/O per keystroke. */
    internal fun validateFirstSendStamp(stamp: String) {
        requirePairingStamp(stamp, contexts.currentPairingStamp())
    }
    fun validateContext(contextId: String?) {
        contextLease(contextId)
    }
    fun closeContext(contextId: String) {
        documentStorage.closeReadersForContext(contextId)
        if (contextId == ContextRegistry.PRIMARY_CONTEXT_ID) {
            val change = watchHub.removeContext(contextId)
            change.stoppedSessions.forEach { stopSessionWatch(it, release = true) }
            change.leasePolicyChangedSessions.forEach(::wakeSessionHeartbeat)
            closeSocketsFor(contextId)
            return
        }
        val closed = contexts.closeContext(contextId) ?: return
        val change = watchHub.removeContext(contextId)
        change.stoppedSessions.forEach { stopSessionWatch(it, release = true) }
        change.leasePolicyChangedSessions.forEach(::wakeSessionHeartbeat)
        closeSocketsFor(closed.contextId)
    }
    fun closeAllContexts(releaseLeases: Boolean = true) {
        appRequests.revokeAll()
        documentStorage.closeAllReaders()
        contexts.invalidateAll()
        val change = watchHub.clear()
        change.stoppedSessions.forEach { stopSessionWatch(it, release = releaseLeases) }
        closeSockets()
        watched = null
        latest = null
    }
    suspend fun pair(link: String): Map<String, Any?> {
        val pairing = PairingLink.parse(link)
        val candidate = connectedApi(pairing)
        candidate.sessions() // Verify before replacing the saved connection.
        return answerLock.withLock {
            closeAllContexts(releaseLeases = true)
            val previous = withContext(Dispatchers.IO) { credentials.load() }
            if (previous != pairing) {
                rotatePairingStamp()
                withContext(Dispatchers.IO) { documentCookies.bind(null); documentStorage.bind(null) }
                GatewayNotifications.clearQuestionNotifications(context)
                dev.pirc.android.push.PushRegistration.disable(context, activeApi ?: previous?.let { connectedApi(it) })
                local.clearDrafts(); uncertain.edit().clear().commit()
                context.getSharedPreferences("recent_activity", Context.MODE_PRIVATE).edit().clear().apply()
            }
            withContext(Dispatchers.IO) { credentials.save(pairing) }
            retireManagement()
            activeApi = candidate
            val stamp = ensurePairingStamp()
            contexts.bindPairingStamp(stamp)
            val result = mapOf("origin" to pairing.baseUrl, "clientId" to local.clientId, "pairingStamp" to stamp)
            emitAccount("pairingChanged", result)
            result
        }
    }
    suspend fun unpair() {
        answerLock.withLock {
            closeAllContexts(releaseLeases = true)
            dev.pirc.android.push.PushRegistration.disable(context, activeApi)
            val stamp = rotatePairingStamp()
            withContext(Dispatchers.IO) { documentCookies.bind(null); documentStorage.bind(null) }
            GatewayNotifications.clearQuestionNotifications(context)
            withContext(Dispatchers.IO) { credentials.clear() }
            retireManagement()
            activeApi = null
            latest = null
            local.clearDrafts()
            uncertain.edit().clear().commit()
            contexts.bindPairingStamp(null)
            emitAccount("pairingChanged", mapOf(
                "origin" to null,
                "clientId" to local.clientId,
                "pairingStamp" to stamp,
            ))
        }
    }
    fun emit(type: String, data: Any?, sessionId: String? = watched) {
        emitEvent(type, data, sessionId)
    }
    private fun emitAccount(type: String, data: Any?) {
        emitEvent(type, data, sessionId = null, scopeName = "account")
    }
    fun notifyPreferencesChanged(preferences: Map<String, Any>) {
        emitAccount("preferencesChanged", preferences)
    }
    internal fun externalDropLease(contextId: String?): ContextRegistry.Lease = contextLease(contextId)
    internal fun externalDropLeaseIsCurrent(lease: ContextRegistry.Lease): Boolean =
        contextLeaseIsCurrent(lease)

    internal fun emitExternalImageDrop(target: ExternalImageDropTarget, dropId: String, files: List<Map<String, Any>>) {
        scope.launch {
            if (!contextLeaseIsCurrent(target.lease)) return@launch
            val event = scopedEventWire(
                type = "externalImageDrop",
                data = mapOf(
                    "targetId" to target.targetId,
                    "scopeToken" to target.scopeToken,
                    "dropId" to dropId,
                    "files" to files,
                ),
                sessionId = target.sessionId,
                contextId = target.contextId,
            )
            listener?.invoke(event)
        }
    }

    private fun emitEvent(
        type: String,
        data: Any?,
        sessionId: String?,
        contextId: String? = null,
        eventTag: String? = null,
        scopeName: String? = null,
    ) {
        val event = scopedEventWire(
            type = type,
            data = data,
            sessionId = sessionId,
            contextId = contextId,
            watchTag = eventTag,
            scopeName = scopeName,
        )
        scope.launch { listener?.invoke(event) }
    }
    private fun contextLease(contextId: String?): ContextRegistry.Lease = try {
        contexts.requireContext(contextId)
    } catch (e: ContextRegistryException) {
        throw ApiException(409, "context_expired", e.message ?: NativeI18n.text("此原生視窗已關閉"))
    }
    private fun contextLeaseIsCurrent(lease: ContextRegistry.Lease): Boolean = contexts.isCurrent(lease)
    private fun emitToSubscriber(
        subscription: SessionWatchSubscription,
        type: String,
        data: Any?,
    ) {
        val lease = try {
            contextLease(subscription.contextId)
        } catch (_: ApiException) {
            return
        }
        scope.launch {
            if (!contextLeaseIsCurrent(lease) ||
                !watchHub.isCurrent(subscription.sessionId, subscription.contextId, subscription.eventTag)
            ) return@launch
            emitEvent(
                type,
                data,
                subscription.sessionId,
                contextId = subscription.contextId,
                eventTag = subscription.eventTag,
            )
        }
    }
    private fun emitSessionWatch(entry: SessionWatchState, type: String, data: Any?) {
        if (sessionWatches[entry.sessionId] !== entry) return
        watchHub.subscribers(entry.sessionId).forEach { emitToSubscriber(it, type, data) }
    }
    private fun updatePrimaryProjection(entry: SessionWatchState) {
        val primary = watchHub.subscription(ContextRegistry.PRIMARY_CONTEXT_ID)
        if (primary?.sessionId == entry.sessionId) latest = entry.latest
    }
    suspend fun request(method: String, path: String, body: Any?): Any? = withContext(Dispatchers.IO) {
        require(path.startsWith("/api/") && !path.contains('\\') && !path.contains('#'))
        requestWithApi(api(), method, path, body)
    }
    internal suspend fun requestWithApi(api: PircApi, method: String, path: String, body: Any?): Any? = withContext(Dispatchers.IO) {
        require(path.startsWith("/api/") && !path.contains('\\') && !path.contains('#'))
        val payload = if (method in listOf("GET", "HEAD")) null else body.json().toString().toRequestBody("application/json".toMediaType())
        api.client.newCall(api.request(path).header("Accept", "application/json").method(method, payload).build()).execute().use { response ->
            val text = response.body?.string().orEmpty()
            val json = runCatching { PircJson.parseToJsonElement(text) }.getOrNull()
            if (!response.isSuccessful) throw api.failure(response, text)
            if (response.code == 204) null else json?.wire() ?: throw ApiException(502, "bad_reply", NativeI18n.text("伺服器回傳的內容不是 JSON，請檢查 gateway 與反向代理"))
        }
    }
    internal suspend fun documentStorageState(
        principal: NativeDocumentScripts.ResourcePrincipal,
        documentUrl: String,
        operations: List<Map<*, *>> = emptyList(),
        knownRevision: Long? = null,
        expectedGeneration: Long? = null,
    ): Map<String, Any?> = withContext(Dispatchers.IO) {
        answerLock.withLock {
            val pairing = credentials.load()
            val stamp = pairing?.let { ensurePairingStamp() }
            if (principal.pairingStamp != stamp) {
                throw ApiException(409, "account_changed", NativeI18n.text("Browser storage account changed; reload the document."))
            }
            val lease = contextLease(principal.contextId)
            if (!contextLeaseIsCurrent(lease) || lease.pairingStamp != stamp) {
                throw ApiException(409, "context_expired", NativeI18n.text("The browser storage context is no longer current."))
            }
            documentStorage.state(principal, documentUrl, operations, knownRevision, expectedGeneration)
        }
    }

    internal suspend fun documentStorageWindow(
        open: Boolean, key: String, openerKey: String?, expectedStamp: String,
    ) = withContext(Dispatchers.IO) {
        answerLock.withLock {
            credentials.load() ?: throw ApiException(401, "unpaired", NativeI18n.text("請先配對此裝置"))
            requirePairingStamp(expectedStamp, ensurePairingStamp())
            if (open) documentStorage.openWindow(expectedStamp, key, openerKey)
            else documentStorage.closeWindow(expectedStamp, key)
        }
    }

    internal suspend fun documentStorageCloseReader(owner: String, contextId: String?) = answerLock.withLock {
        documentStorage.closeReader(owner, contextId)
    }

    internal suspend fun documentCookieState(
        principal: NativeDocumentScripts.ResourcePrincipal,
        documentUrl: String,
        writes: List<Map<*, *>> = emptyList(),
    ): Map<String, Any?> = answerLock.withLock {
        val pairing = withContext(Dispatchers.IO) { credentials.load() }
        val stamp = pairing?.let { ensurePairingStamp() }
        if (principal.pairingStamp != stamp) {
            throw ApiException(409, "account_changed", NativeI18n.text("Cookie account changed; reload the document."))
        }
        val lease = contextLease(principal.contextId)
        if (!contextLeaseIsCurrent(lease) || lease.pairingStamp != principal.pairingStamp) {
            throw ApiException(409, "context_expired", NativeI18n.text("This native context is no longer current."))
        }
        val url = documentUrl.toHttpUrlOrNull()
            ?: throw ApiException(400, "cookie_document", NativeI18n.text("Cookies require an HTTP document."))
        if (NativeScriptResourceTransport.originForDocument(url.toString()) != principal.documentOrigin) {
            throw ApiException(400, "cookie_document", NativeI18n.text("Cookie document origin changed."))
        }
        require(writes.size <= 256) { "Too many cookie writes" }
        val jar = withContext(Dispatchers.IO) { documentCookies.bind(principal.pairingStamp) }!!
        for (write in writes) {
            val writeUrl = (write["url"] as? String)?.toHttpUrlOrNull()
                ?: throw ApiException(400, "cookie_document", NativeI18n.text("Invalid cookie write URL."))
            if (NativeScriptResourceTransport.originForDocument(writeUrl.toString()) != principal.documentOrigin) {
                throw ApiException(400, "cookie_document", NativeI18n.text("Cookie write origin changed."))
            }
            val line = write["line"] as? String ?: throw ApiException(400, "cookie_document", NativeI18n.text("Invalid cookie assignment."))
            require(line.length <= 4096) { "Cookie assignment is too long" }
            val generation = (write["generation"] as? Number)?.toLong()
                ?: throw ApiException(400, "cookie_document", NativeI18n.text("Cookie scope generation is required."))
            jar.setDocumentCookie(writeUrl, line, expectedGeneration = generation)
        }
        jar.exportScriptState(url) + mapOf("persistenceError" to documentCookies.persistenceError)
    }

    internal suspend fun documentPrepareRequest(
        source: String,
        baseUrl: String?,
        expectedStamp: String,
        method: String,
        resourceType: String,
        initiatorUrl: String?,
        topLevelUrl: String?,
    ): Map<String, Any?> = answerLock.withLock {
        withContext(Dispatchers.IO) {
            credentials.load() ?: throw ApiException(401, "unpaired", NativeI18n.text("請先配對此裝置"))
            requirePairingStamp(expectedStamp, ensurePairingStamp())
            val url = NativeDocumentTransport(null).resolveUrl(source, baseUrl).toHttpUrlOrNull()
                ?: throw ApiException(400, "cookie_document", NativeI18n.text("Cookie request requires HTTP."))
            val jar = documentCookies.bind(expectedStamp)!!
            val initiator = nativeCookieContextUrl(initiatorUrl, url.takeIf { resourceType == "document" })
            // Mirrors the transport: content requests never use the paired origin's cookie scope.
            val pairingOrigin = pairingOriginUrl(credentials.load())
            val header = if (!cookiesMayApply(RequestInitiator.Content, null, pairingOrigin, url)) null else jar.requestHeader(url, CookieRequestContext(
                initiatorUrl = initiator, topLevelUrl = nativeCookieContextUrl(topLevelUrl, initiator),
                method = method, topLevelNavigation = resourceType == "document",
            ))
            mapOf("nativeCookieRequestKey" to opaqueCookieRequestKey(header))
        }
    }

    private fun pairingOriginUrl(pairing: Pairing?): HttpUrl? =
        pairing?.baseUrl?.toHttpUrlOrNull()

    /**
     * Loads one Gateway image for an app-owned surface (for example an attachment preview). The
     * app resolves the reference itself: only an `/api/` path on the paired origin is accepted,
     * the credential is attached by this native code path alone, and it is dropped for good if a
     * redirect leaves the origin. Page content cannot reach this method's trust: the engine's
     * `image` request never takes this path.
     */
    suspend fun appImage(path: String): Map<String, Any> = withContext(Dispatchers.IO) {
        require(
            path.length <= 4096 && path.startsWith("/api/") && !path.startsWith("//") &&
                path.none { it.code < 0x21 || it.code == 0x7f || it == '\\' || it == '#' } &&
                path.substringBefore('?').split('/').none { it == ".." || it == "." },
        ) { "Invalid app image path" }
        val captured = answerLock.withLock {
            val pairing = credentials.load()
                ?: throw ApiException(401, "unpaired", NativeI18n.text("請先配對此裝置"))
            Triple(pairing, ensurePairingStamp(), appRequests.issue(pairing))
        }
        val image = NativeImageTransport(
            captured.first,
            cookies = null,
            initiator = captured.third,
        ).load(captured.first.baseUrl + path)
        answerLock.withLock {
            val currentPairing = credentials.load()
            val currentStamp = currentPairing?.let { ensurePairingStamp() }
            check(currentPairing == captured.first && currentStamp == captured.second) {
                NativeI18n.text("Image connection changed")
            }
        }
        image
    }

    suspend fun document(
        source: String,
        method: String,
        body: String?,
        contentType: String?,
        baseUrl: String?,
        pairingStamp: String,
        resourceType: NativeDocumentTransport.ResourceType = NativeDocumentTransport.ResourceType.DOCUMENT,
        cacheMode: NativeDocumentTransport.CacheMode = NativeDocumentTransport.CacheMode.DEFAULT,
        ifNoneMatch: String? = null,
        ifModifiedSince: String? = null,
        bodyBytes: ByteArray? = null,
        referrerUrl: String? = null,
        referrerPolicy: String? = null,
        originUrl: String? = null,
        initiatorUrl: String? = null,
        topLevelUrl: String? = null,
    ): Map<String, Any?> = withContext(Dispatchers.IO) {
        val captured = answerLock.withLock {
            val current = credentials.load() ?: throw ApiException(401, "unpaired", NativeI18n.text("請先配對此裝置"))
            requirePairingStamp(pairingStamp, ensurePairingStamp())
            current to documentCookies.bind(pairingStamp)
        }
        val pairing = captured.first
        val response = NativeDocumentTransport(pairing, cookies = captured.second).load(
            source,
            method,
            body,
            contentType,
            baseUrl,
            resourceType,
            cacheMode,
            ifNoneMatch,
            ifModifiedSince,
            bodyBytes,
            referrerUrl,
            referrerPolicy,
            originUrl,
            initiatorUrl = initiatorUrl ?: originUrl ?: referrerUrl,
            topLevelUrl = topLevelUrl ?: initiatorUrl ?: originUrl ?: referrerUrl,
        )
        answerLock.withLock {
            requirePairingStamp(pairingStamp, if (credentials.load() == pairing) ensurePairingStamp() else null)
        }
        response
    }

    /** Loads one script/fetch resource for the native document principal bound to its isolate. */
    internal suspend fun documentScriptResource(
        principal: NativeDocumentScripts.ResourcePrincipal,
        request: NativeScriptResourceTransport.ResourceRequest,
        cancellation: NativeResourceCancellation? = null,
    ): NativeScriptResourceTransport.ResourceResponse = withContext(Dispatchers.IO) {
        cancellation?.throwIfCancelled()
        val access = answerLock.withLock {
            val pairing = credentials.load()
            val stamp = pairing?.let { ensurePairingStamp() }
            if (principal.pairingStamp != stamp) {
                throw ApiException(409, "account_changed", NativeI18n.text("配對帳戶已變更，請重新載入文件"))
            }
            if (contexts.currentPairingStamp() != stamp) {
                closeAllContexts(releaseLeases = true)
                contexts.bindPairingStamp(stamp)
            }
            val lease = contextLease(principal.contextId)
            if (!contextLeaseIsCurrent(lease) || lease.pairingStamp != stamp) {
                throw ApiException(409, "context_expired", NativeI18n.text("This native context is no longer current."))
            }
            ScriptResourceAccess(pairing, stamp, lease, documentCookies.bind(stamp))
        }

        val response = NativeScriptResourceTransport(access.pairing, cookies = access.cookies).load(
            sourceOrigin = principal.documentOrigin,
            request = request,
            baseUrl = principal.documentUrl,
            referrerUrl = if (request.kind == NativeScriptResourceTransport.Kind.STYLESHEET) {
                request.stylesheetReferrerUrl ?: principal.documentUrl
            } else if (request.kind == NativeScriptResourceTransport.Kind.MODULE_SCRIPT) {
                request.moduleReferrerUrl?.let { referrer ->
                    principal.scriptSources?.requireScriptReferrer(referrer, principal.documentUrl)
                        ?: throw IllegalArgumentException("Module referrer requires an owning document script session")
                } ?: principal.documentUrl
            } else principal.documentUrl,
            cancellation = cancellation,
            initiatorUrl = principal.documentUrl,
            topLevelUrl = principal.documentUrl,
        )
        cancellation?.throwIfCancelled()

        answerLock.withLock {
            val currentPairing = credentials.load()
            val currentStamp = currentPairing?.let { ensurePairingStamp() }
            if (currentPairing != access.pairing || currentStamp != access.pairingStamp ||
                principal.pairingStamp != currentStamp
            ) {
                throw ApiException(409, "account_changed", NativeI18n.text("配對帳戶已變更，請重新載入文件"))
            }
            if (!contextLeaseIsCurrent(access.contextLease)) {
                throw ApiException(409, "context_expired", NativeI18n.text("This native context is no longer current."))
            }
        }
        response
    }

    /** Loads trusted initial HTML CSS through the same cookie, CORS, MIME, SRI and redirect path as script-owned CSS. */
    internal suspend fun documentStylesheet(
        documentUrl: String,
        blobCreatorUrl: String?,
        contextId: String?,
        expectedPairingStamp: String,
        request: NativeScriptResourceTransport.ResourceRequest,
    ): NativeScriptResourceTransport.ResourceResponse = withContext(Dispatchers.IO) {
        require(request.kind == NativeScriptResourceTransport.Kind.STYLESHEET) {
            "Initial document stylesheet requests must use the stylesheet resource kind"
        }
        require(expectedPairingStamp.isNotBlank()) { "A current pairing stamp is required for stylesheet requests" }
        val sourceOrigin = NativeScriptResourceTransport.originForDocument(documentUrl, blobCreatorUrl)
        val principal = answerLock.withLock {
            val pairing = credentials.load()
                ?: throw ApiException(401, "unpaired", NativeI18n.text("請先配對此裝置"))
            val stamp = ensurePairingStamp()
            requirePairingStamp(expectedPairingStamp, stamp)
            if (contexts.currentPairingStamp() != stamp) {
                closeAllContexts(releaseLeases = true)
                contexts.bindPairingStamp(stamp)
            }
            val lease = contextLease(contextId)
            if (!contextLeaseIsCurrent(lease) || lease.pairingStamp != stamp) {
                throw ApiException(409, "context_expired", NativeI18n.text("This native window is no longer current."))
            }
            NativeDocumentScripts.ResourcePrincipal(
                documentUrl = documentUrl,
                documentOrigin = sourceOrigin,
                contextId = lease.contextId,
                pairingStamp = stamp,
            )
        }
        documentScriptResource(principal, request)
    }

    /** Captures the account and native-window lease that own one HTML media element. */
    internal suspend fun captureHtmlMediaAccess(
        contextId: String?,
        expectedPairingStamp: String,
    ): HtmlMediaAccess = answerLock.withLock {
        val pairing = withContext(Dispatchers.IO) { credentials.load() }
            ?: throw ApiException(401, "unpaired", NativeI18n.text("請先配對此裝置"))
        val currentStamp = ensurePairingStamp()
        requirePairingStamp(expectedPairingStamp, currentStamp)
        if (contexts.currentPairingStamp() != currentStamp) {
            closeAllContexts(releaseLeases = true)
            contexts.bindPairingStamp(currentStamp)
        }
        val lease = contextLease(contextId)
        if (lease.pairingStamp != currentStamp) {
            throw ApiException(409, "context_expired", NativeI18n.text("This native context is no longer current."))
        }
        HtmlMediaAccess(pairing, currentStamp, lease, withContext(Dispatchers.IO) { documentCookies.bind(currentStamp) })
    }

    /** Revalidates both owners immediately before a media operation touches the player. */
    internal suspend fun validateHtmlMediaAccess(access: HtmlMediaAccess) = answerLock.withLock {
        val currentPairing = withContext(Dispatchers.IO) { credentials.load() }
        if (currentPairing != access.pairing) {
            throw ApiException(409, "account_changed", NativeI18n.text("配對帳戶已變更，請重新檢查問題"))
        }
        requirePairingStamp(
            access.pairingStamp,
            if (currentPairing == access.pairing) ensurePairingStamp() else null,
        )
        if (!contextLeaseIsCurrent(access.contextLease)) {
            throw ApiException(409, "context_expired", NativeI18n.text("This native context is no longer current."))
        }
    }

    /** Loads a bounded HTTP(S) media representation with the pairing-scoped bearer transport. */
    internal suspend fun loadHtmlMediaResource(
        access: HtmlMediaAccess,
        source: String,
        baseUrl: String?,
        documentUrl: String? = null,
    ): HtmlMediaResource {
        validateHtmlMediaAccess(access)
        val response = withContext(Dispatchers.IO) {
            NativeDocumentTransport(access.pairing, cookies = access.cookies).load(
                url = source,
                method = "GET",
                body = null,
                contentType = null,
                baseUrl = baseUrl,
                resourceType = NativeDocumentTransport.ResourceType.MEDIA,
                initiatorUrl = documentUrl,
                topLevelUrl = documentUrl,
            )
        }
        val status = (response["status"] as? Number)?.toInt()
            ?: throw IllegalStateException(NativeI18n.text("Media response did not include an HTTP status"))
        if (status !in 200..299) {
            throw ApiException(status, "media_http_error", NativeI18n.text("Media request failed with HTTP {0}", status))
        }
        val bytes = response["bytes"] as? ByteArray
            ?: throw IllegalStateException(NativeI18n.text("Media response did not include bytes"))
        if (bytes.size > MAX_HTML_MEDIA_BYTES) {
            throw IllegalArgumentException(NativeI18n.text("Media exceeds the 32 MiB limit"))
        }
        validateHtmlMediaAccess(access)
        val headers = (response["headersRelevant"] as? Map<*, *>)
            ?.mapNotNull { (name, value) ->
                if (name is String && value is String) name to value else null
            }
            ?.toMap()
            .orEmpty()
        return HtmlMediaResource(
            bytes = bytes,
            mimeType = response["mimeType"] as? String ?: "",
            finalUrl = response["finalUrl"] as? String ?: "",
            headersRelevant = headers,
        )
    }

    suspend fun image(source: String, baseUrl: String? = null, documentUrl: String? = null, crossOrigin: String? = null): Map<String, Any> = withContext(Dispatchers.IO) {
        val captured = answerLock.withLock {
            val pairing = credentials.load()
            val stamp = pairing?.let { ensurePairingStamp() }
            Triple(pairing, stamp, documentCookies.bind(stamp))
        }
        val image = if (crossOrigin == null) {
            NativeImageTransport(captured.first, cookies = captured.third).load(
                source, baseUrl, initiatorUrl = documentUrl, topLevelUrl = documentUrl,
            )
        } else {
            require(crossOrigin in setOf("", "anonymous", "use-credentials")) { "Invalid image crossorigin" }
            val sourceOrigin = documentUrl?.let { NativeScriptResourceTransport.originForDocument(it) }
                ?: throw IllegalArgumentException(NativeI18n.text("A CORS image requires its document URL"))
            val response = NativeScriptResourceTransport(captured.first,
                responseLimit = 32 * 1024 * 1024, cookies = captured.third).load(
                sourceOrigin,
                NativeScriptResourceTransport.ResourceRequest(source,
                    kind = NativeScriptResourceTransport.Kind.IMAGE, crossOrigin = crossOrigin),
                baseUrl = baseUrl,
                referrerUrl = documentUrl,
                initiatorUrl = documentUrl,
                topLevelUrl = documentUrl,
            )
            require(response.status in 200..299) { NativeI18n.text("Image request failed ({0})", response.status) }
            mapOf("bytes" to (response.body ?: error(NativeI18n.text("Image response has no bytes"))),
                "mimeType" to response.mimeType,
                "nativeCookieRequestKey" to response.nativeCookieRequestKey,
                "nativeSetCookieProcessed" to response.nativeSetCookieProcessed)
        }
        answerLock.withLock {
            val currentPairing = credentials.load()
            val currentStamp = currentPairing?.let { ensurePairingStamp() }
            check(currentPairing == captured.first && currentStamp == captured.second &&
                documentCookies.bind(currentStamp) === captured.third) { NativeI18n.text("Image connection changed") }
        }
        image
    }
    suspend fun snapshot(id: String): SessionState {
        val owner = sessionWatches[id]
        val state = snapshotState(api().snapshot(id))
        if (owner != null && sessionWatches[id] === owner) {
            owner.composerSettings.observedApprovalSnapshot(state.approvalMode)
        }
        return state
    }

    /** True only when at least one subscribed app context currently shows this session. */
    fun hasVisibleSessionSubscriber(sessionId: String): Boolean =
        watchHub.hasVisibleSubscriber(sessionId)

    suspend fun snapshotForInteraction(id: String): Pair<SessionState, String> = answerLock.withLock {
        val pairing = withContext(Dispatchers.IO) { credentials.load() }
            ?: throw ApiException(401, "unpaired", NativeI18n.text("請先配對此裝置"))
        snapshot(id) to ensurePairingStamp()
    }

    /** Run a short local notification update atomically with pair/unpair changes. */
    suspend fun withCurrentPairingStamp(action: (String) -> Unit) = answerLock.withLock {
        withContext(Dispatchers.IO) { credentials.load() }
            ?: throw ApiException(401, "unpaired", NativeI18n.text("請先配對此裝置"))
        action(ensurePairingStamp())
    }

    /** A revoke may safely clear its exact old note while unpaired; pair changes serialize this update. */
    suspend fun withOptionalPairingStamp(action: (String?) -> Unit) = answerLock.withLock {
        val paired = withContext(Dispatchers.IO) { credentials.load() } != null
        action(if (paired) ensurePairingStamp() else null)
    }

    fun watch(id: String, contextId: String? = null, eventTag: String? = null) {
        val context = contextLease(contextId)
        require(eventTag == null || (eventTag.isNotBlank() && eventTag.length <= 128)) {
            "Invalid eventTag"
        }
        val scopedTag = eventTag ?: context.contextId.takeUnless {
            it == ContextRegistry.PRIMARY_CONTEXT_ID
        }?.let { UUID.randomUUID().toString() }
        val change = watchHub.subscribe(id, context.contextId, scopedTag)
        if (change.sessionDeleted) {
            emitEvent(
                "sessionDeleted",
                mapOf("sessionId" to id),
                id,
                contextId = context.contextId,
                eventTag = scopedTag,
            )
            return
        }
        val subscription = requireNotNull(change.subscription)
        change.stoppedSessions.forEach { stopSessionWatch(it, release = true) }
        if (context.contextId == ContextRegistry.PRIMARY_CONTEXT_ID) watched = id

        val entry = sessionWatches.getOrPut(id) { SessionWatchState(id) }
        val startsWatcher = entry.watcher?.isActive != true
        if (startsWatcher) {
            startSessionWatch(entry)
        } else {
            emitToSubscriber(subscription, "connection", entry.connection)
            entry.latest?.let { emitToSubscriber(subscription, "snapshot", it.wire()) }
            // The pooled heartbeat already owns lease refresh for this session.
            // It will emit its current control result to every subscriber.
        }
        change.leasePolicyChangedSessions
            .filterNot { it == id && startsWatcher }
            .forEach(::wakeSessionHeartbeat)
        updatePrimaryProjection(entry)
    }
    fun unwatch(release: Boolean = false) = unwatch(contextId = null, eventTag = null, release = release)

    fun unwatch(contextId: String?, eventTag: String? = null, release: Boolean = false) {
        val context = contextLease(contextId)
        val current = watchHub.subscription(context.contextId) ?: return
        if (eventTag != null && current.eventTag != eventTag) return
        val change = watchHub.unsubscribe(context.contextId, eventTag)
        change.stoppedSessions.forEach { stopSessionWatch(it, release) }
        change.leasePolicyChangedSessions.forEach(::wakeSessionHeartbeat)
        if (context.contextId == ContextRegistry.PRIMARY_CONTEXT_ID) {
            watched = watchHub.subscription(ContextRegistry.PRIMARY_CONTEXT_ID)?.sessionId
            latest = watched?.let { sessionWatches[it]?.latest }
        }
    }

    fun setWatchVisibility(
        contextId: String?,
        visible: Boolean,
        visibilityRevision: Long,
        eventTag: String? = null,
    ): Boolean {
        val context = contextLease(contextId)
        require(eventTag == null || (eventTag.isNotBlank() && eventTag.length <= 128)) {
            "Invalid eventTag"
        }
        val change = watchHub.setVisibility(
            context.contextId,
            visible,
            visibilityRevision,
            eventTag,
        )
        change.leasePolicyChangedSessions.forEach(::wakeSessionHeartbeat)
        return !change.staleTag && !change.staleVisibility
    }

    private fun startSessionWatch(entry: SessionWatchState) {
        entry.connection = "connecting"
        entry.watcher = scope.launch {
            var attempt = 0
            while (isActive && sessionWatches[entry.sessionId] === entry) {
                try {
                    entry.connection = "connecting"
                    emitSessionWatch(entry, "connection", entry.connection)
                    val settingsRevision = entry.composerSettings.revision
                    var state = snapshot(entry.sessionId)
                    if (sessionWatches[entry.sessionId] !== entry) break
                    state = entry.composerSettings.mergeFetched(state, settingsRevision)
                    entry.latest = state
                    updatePrimaryProjection(entry)
                    GatewayNotifications.sync(context, state, questionPairingStamp = ensurePairingStamp())
                    emitSessionWatch(entry, "snapshot", state.wire())
                    EventStream(api(), onChange = { type ->
                        scope.launch {
                            if (sessionWatches[entry.sessionId] === entry) {
                                emitSessionWatch(entry, "indexChange", type)
                            }
                        }
                    }).open(entry.sessionId, state.cursor).collect { signal ->
                        if (sessionWatches[entry.sessionId] !== entry) return@collect
                        when (signal) {
                            StreamSignal.Connected -> {
                                attempt = 0
                                entry.connection = "live"
                                emitSessionWatch(entry, "connection", entry.connection)
                            }
                            StreamSignal.Reconnecting -> {
                                entry.connection = "reconnecting"
                                emitSessionWatch(entry, "connection", entry.connection)
                            }
                            is StreamSignal.Closed -> throw signal.error
                            is StreamSignal.Event -> {
                                val before = entry.latest ?: state
                                val event = signal.envelope.event
                                if (event == TimelineEvent.SessionDeleted) {
                                    emitSessionWatch(
                                        entry,
                                        "sessionDeleted",
                                        mapOf("sessionId" to entry.sessionId),
                                    )
                                    watchHub.markDeleted(entry.sessionId)
                                    stopSessionWatch(entry.sessionId, release = false)
                                    return@collect
                                }
                                if (event == TimelineEvent.CheckpointsChanged) {
                                    emitSessionWatch(entry, "checkpoints_changed", null)
                                }
                                if (event is TimelineEvent.PanelChanged) {
                                    emitSessionWatch(entry, "panelChange", event.sections)
                                }
                                state = before.reduce(signal.envelope)
                                if (!state.needsSnapshot && event is TimelineEvent.ApprovalModeChanged) {
                                    entry.composerSettings.authoritativeApprovalMode(event.mode)
                                }
                                GatewayNotifications.sync(context, state, before, ensurePairingStamp())
                                if (state.needsSnapshot) throw Resnapshot()
                                entry.latest = state
                                updatePrimaryProjection(entry)
                                if (entry.pendingSnapshot?.isActive != true) {
                                    entry.pendingSnapshot = scope.launch {
                                        delay(32)
                                        if (sessionWatches[entry.sessionId] === entry) {
                                            entry.latest?.let {
                                                emitSessionWatch(entry, "snapshot", it.wire())
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } catch (_: Resnapshot) {
                    continue
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    if (sessionWatches[entry.sessionId] !== entry) break
                    emitSessionWatch(entry, "error", e.message)
                    if (e is ApiException && e.status in listOf(401, 403, 404)) {
                        entry.connection = "stopped"
                        emitSessionWatch(entry, "connection", entry.connection)
                        break
                    }
                    entry.connection = "reconnecting"
                    emitSessionWatch(entry, "connection", entry.connection)
                    delay(minOf(20_000L, 750L shl minOf(attempt++, 5)))
                }
            }
        }
        startSessionHeartbeat(entry)
    }

    private fun startSessionHeartbeat(entry: SessionWatchState) {
        entry.heartbeats?.cancel()
        entry.heartbeatWake?.close()
        val wake = Channel<Unit>(Channel.CONFLATED)
        entry.heartbeatWake = wake
        entry.heartbeats = scope.launch {
            while (isActive && sessionWatches[entry.sessionId] === entry && entry.heartbeatWake === wake) {
                val policy = watchHub.leasePolicy(entry.sessionId)
                val control = try {
                    lease(entry.sessionId, acquire = policy.mayAcquire)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    null
                }
                // A lease request can finish after the final subscriber leaves
                // or another heartbeat replaces this one. Do not publish stale
                // control state or wait on the retired wake channel.
                if (!isActive || sessionWatches[entry.sessionId] !== entry || entry.heartbeatWake !== wake) break
                if (control != null) emitSessionWatch(entry, "control", control)
                if (!awaitSessionHeartbeatWake(wake, policy.intervalMs)) break
            }
        }
    }

    private fun wakeSessionHeartbeat(sessionId: String) {
        sessionWatches[sessionId]?.heartbeatWake?.trySend(Unit)
    }

    private fun stopSessionWatch(sessionId: String, release: Boolean) {
        val entry = sessionWatches.remove(sessionId) ?: return
        entry.watcher?.cancel()
        entry.heartbeats?.cancel()
        entry.heartbeatWake?.close()
        entry.pendingSnapshot?.cancel()
        GatewayNotifications.manager(context).cancel(("progress:$sessionId").hashCode())
        if (watched == sessionId && watchHub.subscription(ContextRegistry.PRIMARY_CONTEXT_ID) == null) {
            watched = null
            latest = null
        }
        val oldApi = activeApi
        val generation = heldGenerations.remove(sessionId)
        // Only the final subscription reaches here, so another context's lease
        // heartbeat cannot be invalidated by this context closing.
        if (release && generation != null && oldApi != null) scope.launch {
            runCatching { oldApi.releaseControl(sessionId, local.clientId, generation) }
        }
    }
    suspend fun lease(id: String, acquire: Boolean = false, force: Boolean = false, commandApi: PircApi? = null): Map<String, Any?> {
        val api = commandApi ?: api()
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
    suspend fun generation(id: String, commandApi: PircApi? = null): Long {
        val lease = lease(id, acquire = true, commandApi = commandApi)
        if (lease["held"] != true) throw ApiException(409, "lost_control", NativeI18n.text("控制權在其他裝置，請先明確取得控制權"))
        return lease["generation"] as Long
    }
    fun unknownCommand(id: String) = uncertain.contains("command:$id") || uncertain.contains("command-stop:$id")
    suspend fun acknowledgeCommand(id: String): Boolean {
        val expectedStamp = ensurePairingStamp()
        return commandLock.withLock {
            stopCommandLock.withLock {
                requirePairingStamp(expectedStamp, pairingIdentity.getString("stamp", null))
                // Never reconcile a still-running POST or another pairing's marker.
                uncertain.edit().remove("command:$id").remove("command-stop:$id").commit()
            }
        }
    }
    suspend fun command(id: String, payload: Map<*, *>, commandId: String, expectedBinding: JsonElement? = null): Map<String, Any?> {
        val capturedBinding = expectedBinding?.let(::commandBinding)
        // Stop must reach the server even while a different command POST is
        // waiting for its response. Independent durable markers prevent either
        // completion from clearing the other's unresolved delivery state.
        val expectedStamp = ensurePairingStamp()
        val commandApi = api()
        val stopping = payload["type"] == "stop"
        val lock = if (stopping) stopCommandLock else commandLock
        return lock.withLock { deliverCommand(id, payload, commandId, stopping, commandApi, expectedStamp, capturedBinding) }
    }
    private suspend fun deliverCommand(id: String, payload: Map<*, *>, commandId: String, stopping: Boolean, api: PircApi, expectedStamp: String, expectedBinding: ConversationBinding?): Map<String, Any?> {
        fun currentPairing() = expectedStamp == pairingIdentity.getString("stamp", null)
        requirePairingStamp(expectedStamp, pairingIdentity.getString("stamp", null))
        if (unknownCommand(id) && payload["type"] != "stop") throw ApiException(409, "outcome_unknown", NativeI18n.text("先前送出結果不明，請先檢查對話並確認繼續"))
        val generation = generation(id, commandApi = api)
        requirePairingStamp(expectedStamp, pairingIdentity.getString("stamp", null))
        val key = if (stopping) "command-stop:$id" else "command:$id"
        val pendingBefore = uncertain.getString(key, null)
        uncertain.edit().putString(key, commandId).commit()
        val settingsOwner = sessionWatches[id]
        val observedApprovalRevision = settingsOwner?.composerSettings?.approvalObservationRevision
        try {
            val receipt = api.command(id, local.clientId, generation, commandId, payload.json() as JsonObject, expectedBinding)
            if (currentPairing() && receipt.status == "accepted") {
                sessionWatches[id]?.takeIf { payload["type"] != "set_approval_mode" || it === settingsOwner }?.let { entry ->
                    val revision = entry.composerSettings.revision
                    if (entry.composerSettings.accepted(payload, observedApprovalRevision ?: entry.composerSettings.approvalObservationRevision)) {
                        entry.latest?.let { cached ->
                            val updated = entry.composerSettings.mergeFetched(cached, revision)
                            entry.latest = updated
                            updatePrimaryProjection(entry)
                            emitSessionWatch(entry, "snapshot", updated.wire())
                        }
                    }
                }
            }
            if (currentPairing() && receipt.status != "outcome_unknown") {
                if (pendingBefore != null) uncertain.edit().putString(key, pendingBefore).commit()
                else uncertain.edit().remove(key).commit()
            }
            return mapOf("commandId" to receipt.commandId, "status" to receipt.status, "message" to receipt.message)
        } catch (e: ApiException) {
            if (currentPairing() && e.status in 400..499) {
                if (pendingBefore != null) uncertain.edit().putString(key, pendingBefore).commit()
                else uncertain.edit().remove(key).commit()
            }
            throw e
        }
    }
    suspend fun answer(id: String, interactionId: String, epoch: String, pairingStamp: String, data: Map<*, *>): Map<String, Any?> = answerLock.withLock {
        validatePairingStamp(pairingStamp)
        val key = "$id:$interactionId:$epoch"
        // Check the durable marker before reading the question. If the prior
        // POST was accepted, a fresh snapshot may no longer contain it; the
        // caller still needs the explicit reconciliation action in that case.
        if (uncertain.getBoolean(key, false)) throw ApiException(409, "outcome_unknown", NativeI18n.text("先前回答結果不明，請檢查最新狀態，不可重送"))
        val before = snapshot(id)
        val answer = checkedAnswer(before, interactionId, epoch, data)
        val generation = answerGeneration(interactionId) { generation(id) }
        // Persist before the POST: process death must not turn uncertainty into a retry.
        if (!uncertain.edit().putBoolean(key, true).commit())
            throw ApiException(503, "outcome_unknown", NativeI18n.text("無法保存回答狀態，回答未送出；請檢查最新狀態"))
        try {
            api().answer(id, interactionId, local.clientId, generation, answer)
            if (!uncertain.edit().remove(key).commit())
                throw ApiException(503, "outcome_unknown", NativeI18n.text("回答可能已收到，請檢查最新狀態"))
        } catch (e: ApiException) {
            if (e.status in 400..499 && !uncertain.edit().remove(key).commit())
                throw ApiException(503, "outcome_unknown", NativeI18n.text("回答未送出但無法保存狀態，請檢查最新狀態"))
            throw e
        }
        snapshot(id).wire()
    }
    /**
     * Allow or deny a relayed delegation approval from outside its chat (the
     * session list's "Needs you"). The exact question is read from the chat's
     * fresh snapshot, then answered like any other, without the lease.
     */
    suspend fun answerRelayed(chatId: String, interactionId: String, pairingStamp: String, confirmed: Boolean): Map<String, Any?> {
        if (!isRelayedInteraction(interactionId))
            throw ApiException(400, "invalid_answer", NativeI18n.text("Not a relayed approval"))
        val question = snapshot(chatId).interactions.find { it.id == interactionId }
            ?: throw ApiException(409, "stale", NativeI18n.text("問題已不存在，請重新整理"))
        return answer(chatId, interactionId, question.runnerEpoch, pairingStamp, mapOf("confirmed" to confirmed))
    }
    /** `POST /api/delegations/:id/stop`; no lease. */
    suspend fun stopDelegation(delegationId: String): Map<String, Any?> =
        mapOf("status" to api().stopDelegation(delegationId))
    suspend fun reconcileAnswer(id: String, interactionId: String, epoch: String, pairingStamp: String): Map<String, Any?> = answerLock.withLock {
        validatePairingStamp(pairingStamp)
        // Do not clear the durable uncertainty marker until this fresh read has
        // proved what happened to this exact question on this exact session.
        val before = snapshot(id)
        val result = answerReconciliation(before, id, interactionId, epoch)
        if (!uncertain.edit().remove("$id:$interactionId:$epoch").commit())
            throw ApiException(503, "outcome_unknown", NativeI18n.text("無法保存最新回答狀態，請稍後再檢查"))
        mapOf(
            "sessionId" to id,
            "status" to if (result.pending) "pending" else "resolved",
            "interaction" to result.interaction?.wire(),
        )
    }
    suspend fun openSocket(tag: String, path: String, contextId: String? = null) {
        val contextLease = contextLease(contextId)
        require(path.startsWith("/api/sessions/") && path.endsWith("/stream"))
        val key = SocketKey(contextLease.contextId, tag)
        closeSocketKey(key)
        val token = UUID.randomUUID().toString()
        socketTokens[key] = token
        val api = api()
        if (!contextLeaseIsCurrent(contextLease)) {
            socketTokens.remove(key, token)
            throw ApiException(409, "context_expired", NativeI18n.text("此原生視窗已關閉"))
        }
        val socket = api.client.newBuilder().readTimeout(0, java.util.concurrent.TimeUnit.MILLISECONDS)
            .pingInterval(25, java.util.concurrent.TimeUnit.SECONDS).build()
            .newWebSocket(api.request(path).build(), object: WebSocketListener() {
                private fun current() = socketTokens[key] == token && contextLeaseIsCurrent(contextLease)
                private fun send(type: String, data: Map<String, Any?>) {
                    if (!current()) return
                    emitEvent(type, data, sessionId = null, contextId = contextLease.contextId)
                }
                override fun onOpen(ws: WebSocket, response: Response) {
                    send("socketOpened", mapOf("tag" to tag))
                }
                override fun onMessage(ws: WebSocket, text: String) {
                    send("socket", mapOf("tag" to tag, "frame" to runCatching { PircJson.parseToJsonElement(text).wire() }.getOrNull()))
                }
                override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) {
                    send("socketClosed", mapOf("tag" to tag, "code" to response?.code, "message" to t.message))
                }
                override fun onClosing(ws: WebSocket, code: Int, reason: String) {
                    ws.close(1000, null)
                    send("socketClosed", mapOf("tag" to tag, "code" to code, "message" to reason))
                }
            })
        if (!contextLeaseIsCurrent(contextLease) || socketTokens[key] != token) {
            socket.cancel()
            socketTokens.remove(key, token)
            return
        }
        sockets[key] = socket
    }
    fun sendSocket(tag: String, data: Map<*, *>, contextId: String? = null) {
        val context = contextLease(contextId)
        check(contextLeaseIsCurrent(context)) { NativeI18n.text("此原生視窗已關閉") }
        val key = SocketKey(context.contextId, tag)
        check(sockets[key]?.send(data.json().toString()) == true) { NativeI18n.text("Socket 已斷線") }
    }
    fun closeSocket(tag: String, contextId: String? = null) {
        val context = contextLease(contextId)
        closeSocketKey(SocketKey(context.contextId, tag))
    }
    private fun closeSocketKey(key: SocketKey) {
        socketTokens.remove(key)
        sockets.remove(key)?.cancel()
    }
    private fun closeSocketsFor(contextId: String) {
        socketTokens.keys.filter { it.contextId == contextId }.forEach(::closeSocketKey)
        sockets.keys.filter { it.contextId == contextId }.forEach(::closeSocketKey)
    }
    fun closeSockets() {
        socketTokens.clear()
        sockets.values.forEach { it.cancel() }
        sockets.clear()
    }
    private class Resnapshot: Exception()
    companion object {
        @Volatile private var instance: GatewayRuntime? = null
        fun get(context: Context) = instance ?: synchronized(this) {
            instance ?: GatewayRuntime(context.applicationContext).also { instance = it }
        }
    }
}
