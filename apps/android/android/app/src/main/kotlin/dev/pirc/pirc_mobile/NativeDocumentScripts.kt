package dev.pirc.pirc_mobile

import android.content.Context
import androidx.javascriptengine.IsolateStartupParameters
import androidx.javascriptengine.IsolateTerminatedException
import androidx.javascriptengine.JavaScriptIsolate
import androidx.javascriptengine.JavaScriptSandbox
import androidx.javascriptengine.SandboxDeadException
import androidx.javascriptengine.SandboxUnsupportedException
import androidx.javascriptengine.TerminationInfo
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executor
import java.util.concurrent.ExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal class DocumentScriptException(
    val code: String,
    message: String,
) : Exception(message)

/**
 * One bridge-scoped JavaScript sandbox with a separate persistent isolate per document.
 *
 * [documentGate] is asked, with the document URL this class derives its own origin from, before
 * any execution environment is created; it throws to refuse. The native runtime supplies the check
 * that keeps documents served by the paired origin inert ([PairedOriginPolicy]).
 */
internal class NativeDocumentScripts(
    context: Context,
    private val documentGate: suspend (documentUrl: String, blobCreatorUrl: String?) -> Unit,
) {
    private data class Session(
        val id: Int,
        val owner: String,
        val documentUrl: String,
        val documentOrigin: String,
        val contextId: String,
        val pairingStamp: String?,
        val contextGeneration: Long,
        val storageSessionKey: String,
        val sandbox: JavaScriptSandbox,
        val isolate: JavaScriptIsolate,
        val generation: Long,
        val evaluationLock: Mutex = Mutex(),
        val retired: AtomicBoolean = AtomicBoolean(false),
        val canvasTextPrepared: AtomicBoolean = AtomicBoolean(false),
        val resources: NativeDocumentResourceRequests = NativeDocumentResourceRequests(),
    )

    private data class Reservation(
        val id: Int,
        val generation: Long,
        val sandbox: JavaScriptSandbox,
        val contextGeneration: Long,
    )

    internal data class ResourcePrincipal(
        val documentUrl: String,
        val documentOrigin: String,
        val contextId: String,
        val pairingStamp: String?,
        val scriptOwner: String? = null,
        val storageSessionKey: String? = null,
        val scriptSources: NativeDocumentResourceRequests? = null,
    )

    internal data class ResourceLease(
        val principal: ResourcePrincipal,
        val requestId: String,
        val cancellation: NativeResourceCancellation,
        internal val requests: NativeDocumentResourceRequests,
    )

    // Registered synchronously on the MethodChannel dispatcher before HTTP work
    // suspends. Later cancellation messages therefore cannot overtake registration.
    fun beginResource(id: Int, owner: String, contextId: String?, requestId: String): ResourceLease {
        validateOwner(owner)
        return synchronized(stateLock) {
            val session = requireSession(id, owner, contextId)
            val token = session.resources.begin(requestId)
            ResourceLease(
                ResourcePrincipal(session.documentUrl, session.documentOrigin, session.contextId, session.pairingStamp, session.owner, session.storageSessionKey, session.resources),
                requestId, token, session.resources,
            )
        }
    }

    fun cancelResource(id: Int, owner: String, contextId: String?, requestId: String) {
        validateOwner(owner)
        val requests = synchronized(stateLock) {
            // Retiring already canceled every owned socket. Late cleanup is a
            // no-op; a live session still enforces its exact owner and context.
            if (sessions[id] == null) return
            requireSession(id, owner, contextId).resources
        }
        requests.cancel(requestId)
    }

    fun finishResource(lease: ResourceLease) {
        lease.requests.finish(lease.requestId, lease.cancellation)
    }

    private val appContext = context.applicationContext
    private val stateLock = Any()
    private val sandboxLock = Mutex()
    private val maintenanceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val sessions = mutableMapOf<Int, Session>()
    private val reservedOwners = mutableMapOf<String, Int>()
    private val reservedIds = mutableSetOf<Int>()
    private val contextGenerations = mutableMapOf<String, Long>()
    @Volatile private var sandbox: JavaScriptSandbox? = null
    private var nextId = 1
    private var generation = 0L
    private var pendingCreates = 0
    private var closingIsolates = 0
    @Volatile private var closed = false
    private var hasPairingStamp = false
    private var pairingStamp: String? = null

    suspend fun capabilities(): Map<String, Any> {
        if (closed) return unavailable("The document script engine is closed.")
        return try {
            if (!withContext(Dispatchers.IO) { JavaScriptSandbox.isSupported() }) {
                unavailable(NativeI18n.text("JavaScriptEngine is unavailable on this device."))
            } else {
                val connected = connectedSandbox()
                val missing = withContext(Dispatchers.IO) { missingRequiredFeatures(connected) }
                if (missing.isEmpty()) {
                    mapOf("supported" to true,
                        "canvasTextSupported" to (android.os.Build.VERSION.SDK_INT >= 31 &&
                            listOf(JavaScriptSandbox.JS_FEATURE_WASM_COMPILATION,
                                JavaScriptSandbox.JS_FEATURE_PROVIDE_CONSUME_ARRAY_BUFFER,
                                JavaScriptSandbox.JS_FEATURE_PROMISE_RETURN).all(connected::isFeatureSupported)))
                } else {
                    unavailable(NativeI18n.text("JavaScriptEngine is missing required features: {0}.", missing.joinToString()))
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            unavailable(NativeI18n.text("JavaScriptEngine could not start on this device."))
        }
    }

    suspend fun open(
        owner: String,
        documentUrl: String,
        contextId: String?,
        blobCreatorUrl: String? = null,
        storageSessionKey: String? = null,
    ): Int {
        validateOwner(owner)
        require(storageSessionKey == null || (storageSessionKey.isNotBlank() && storageSessionKey.length <= 256 &&
            storageSessionKey.none { it.code < 0x20 || it.code == 0x7f })) { "Invalid storage window key" }
        require(documentUrl.length <= MAX_DOCUMENT_URL_CHARS) { "Document URL is too long" }
        require(blobCreatorUrl == null || blobCreatorUrl.length <= MAX_DOCUMENT_URL_CHARS) {
            "Blob creator URL is too long"
        }
        val documentOrigin = NativeScriptResourceTransport.originForDocument(documentUrl, blobCreatorUrl)
        // Decided before the sandbox is touched, so a refused document never owns an isolate.
        documentGate(documentUrl, blobCreatorUrl)
        val boundContextId = contextId ?: ContextRegistry.PRIMARY_CONTEXT_ID
        val connected = requireSupportedSandbox()
        val reservation = synchronized(stateLock) {
            ensureOpenLocked()
            if (sessions.values.any { it.owner == owner } || owner in reservedOwners) {
                throw DocumentScriptException("SCRIPT_OWNER", "A script isolate already exists for this document.")
            }
            if (sessions.size + pendingCreates + closingIsolates >= MAX_ISOLATES) {
                throw DocumentScriptException("SCRIPT_CAPACITY", NativeI18n.text("The document script isolate limit has been reached."))
            }
            val id = nextAvailableIdLocked()
            reservedIds += id
            reservedOwners[owner] = id
            pendingCreates += 1
            Reservation(id, generation, connected, contextGenerations[boundContextId] ?: 0L)
        }

        var created: JavaScriptIsolate? = null
        try {
            val isolate = withContext(NonCancellable + Dispatchers.IO) {
                val startup = IsolateStartupParameters().apply {
                    setMaxHeapSizeBytes(MAX_HEAP_BYTES)
                    setMaxEvaluationReturnSizeBytes(MAX_VALUE_BYTES)
                }
                reservation.sandbox.createIsolate(startup)
            }
            created = isolate
            val session = Session(
                id = reservation.id,
                owner = owner,
                documentUrl = documentUrl,
                documentOrigin = documentOrigin,
                contextId = boundContextId,
                pairingStamp = synchronized(stateLock) { pairingStamp },
                contextGeneration = reservation.contextGeneration,
                storageSessionKey = storageSessionKey ?: owner,
                sandbox = reservation.sandbox,
                isolate = isolate,
                generation = reservation.generation,
            )
            isolate.addOnTerminatedCallback(DIRECT_EXECUTOR) { info ->
                if (onIsolateTerminated(session)) {
                    maintenanceScope.launch { closeRetired(session) }
                }
                if (info.status == TerminationInfo.STATUS_SANDBOX_DEAD ||
                    info.status == TerminationInfo.STATUS_MEMORY_LIMIT_EXCEEDED
                ) {
                    maintenanceScope.launch { resetSandboxAfterCrash(session.sandbox) }
                }
            }
            synchronized(stateLock) {
                pendingCreates -= 1
                if (reservedOwners[owner] == reservation.id) reservedOwners.remove(owner)
                reservedIds -= reservation.id
                if (closed || generation != reservation.generation || sandbox !== reservation.sandbox ||
                    (contextGenerations[boundContextId] ?: 0L) != reservation.contextGeneration
                ) {
                    throw DocumentScriptException("SCRIPT_CLOSED", "The document script context closed while opening.")
                }
                sessions[reservation.id] = session
            }
            return reservation.id
        } catch (error: Throwable) {
            synchronized(stateLock) {
                if (reservation.id in reservedIds) {
                    pendingCreates -= 1
                    if (reservedOwners[owner] == reservation.id) reservedOwners.remove(owner)
                    reservedIds -= reservation.id
                }
            }
            created?.let { closeIsolate(it) }
            if (error is CancellationException) throw error
            if (error is DocumentScriptException) throw error
            if (error is SandboxDeadException) resetSandboxAfterCrash(reservation.sandbox)
            throw engineFailure(error)
        }
    }

    /** Only packaged engine bytes and fonts selected by Android's shaper cross this boundary. */
    suspend fun prepareCanvasText(id: Int, owner: String, contextId: String?, families: List<String>, sample: String): Map<String, Any?> {
        validateOwner(owner)
        val session = requireSession(id, owner, contextId)
        require(listOf(JavaScriptSandbox.JS_FEATURE_WASM_COMPILATION,
            JavaScriptSandbox.JS_FEATURE_PROVIDE_CONSUME_ARRAY_BUFFER,
            JavaScriptSandbox.JS_FEATURE_PROMISE_RETURN).all(session.sandbox::isFeatureSupported)) {
            "This JavaScriptSandbox cannot load native Canvas text resources"
        }
        return withContext(Dispatchers.IO) {
            session.evaluationLock.withLock {
                ensureSessionActive(session)
                check(session.canvasTextPrepared.compareAndSet(false, true)) {
                    "Canvas text resources were already prepared for this document"
                }
                val collected = NativeCanvasTextFonts.collect(families, sample)
                val wasmName = "pirc-canvas-text-wasm"
                val wasm = appContext.assets.open("flutter_assets/assets/document-canvas-text.wasm").use { it.readBytes() }
                check(wasm.size in 1..16 * 1024 * 1024) { "Invalid packaged Canvas text engine" }
                val binaryNames = java.util.IdentityHashMap<ByteArray, String>()
                val resources = (collected["resources"] as List<*>).map { raw ->
                    val resource = raw as Map<*, *>
                    val bytes = resource["bytes"] as ByteArray
                    val name = binaryNames[bytes] ?: "pirc-canvas-font-${binaryNames.size}".also {
                        binaryNames[bytes] = it
                    }
                    resource.entries.filter { it.key != "bytes" }.associate { it.key as String to it.value } + ("dataName" to name)
                }
                ensureSessionActive(session)
                session.isolate.provideNamedData(wasmName, wasm)
                for ((bytes, name) in binaryNames) session.isolate.provideNamedData(name, bytes)
                mapOf("wasmName" to wasmName, "resources" to resources, "matches" to collected["matches"],
                    "fontBytes" to binaryNames.keys.sumOf { it.size.toLong() })
            }
        }
    }

    suspend fun evaluate(id: Int, owner: String, source: String, contextId: String?): String {
        validateOwner(owner)
        val session = requireSession(id, owner, contextId)
        return try {
            withContext(Dispatchers.IO) {
                validateSource(source)
                withTimeout(EVALUATION_TIMEOUT_MS) {
                    session.evaluationLock.withLock {
                        ensureSessionActive(session)
                        val value = await(session.isolate.evaluateJavaScriptAsync(source))
                        if (value.toByteArray(StandardCharsets.UTF_8).size > MAX_VALUE_BYTES) {
                            throw DocumentScriptException("SCRIPT_LIMIT", NativeI18n.text("The JavaScript result exceeds 4 MiB."))
                        }
                        value
                    }
                }
            }
        } catch (_: TimeoutCancellationException) {
            retireAndClose(session)
            throw DocumentScriptException("SCRIPT_TIMEOUT", NativeI18n.text("JavaScript evaluation exceeded 2 seconds; the document isolate was closed."))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val cause = unwrap(error)
            when (cause) {
                is SandboxDeadException -> resetSandboxAfterCrash(session.sandbox)
                is IsolateTerminatedException -> retireAndClose(session)
            }
            if (cause is DocumentScriptException) throw cause
            throw engineFailure(cause)
        }
    }

    suspend fun close(id: Int, owner: String, contextId: String?) {
        validateOwner(owner)
        val session = requireSession(id, owner, contextId)
        retireAndClose(session)
    }

    /** Returns the source principal kept by native when this document isolate was opened. */
    fun resourcePrincipal(id: Int, owner: String, contextId: String?): ResourcePrincipal {
        validateOwner(owner)
        val session = requireSession(id, owner, contextId)
        return ResourcePrincipal(
            documentUrl = session.documentUrl,
            documentOrigin = session.documentOrigin,
            contextId = session.contextId,
            pairingStamp = session.pairingStamp,
            scriptOwner = session.owner,
            storageSessionKey = session.storageSessionKey,
            scriptSources = session.resources,
        )
    }

    /** Retires isolates and pending opens owned by one native browsing context. */
    fun closeContext(contextId: String?) {
        val boundContextId = contextId ?: ContextRegistry.PRIMARY_CONTEXT_ID
        val retiring = synchronized(stateLock) {
            contextGenerations[boundContextId] = (contextGenerations[boundContextId] ?: 0L) + 1
            sessions.values.filter { it.contextId == boundContextId }.also { selected ->
                selected.forEach { session ->
                    sessions.remove(session.id)
                    if (session.retired.compareAndSet(false, true)) closingIsolates += 1
                }
            }
        }
        retiring.forEach { it.resources.close() }
        if (retiring.isNotEmpty()) {
            maintenanceScope.launch {
                retiring.forEach { session -> closeRetired(session) }
            }
        }
    }

    /** Pairing changes invalidate every document environment, while preserving the shared engine. */
    fun onPairingStampChanged(value: String?) {
        val changed = synchronized(stateLock) {
            if (!hasPairingStamp) {
                hasPairingStamp = true
                pairingStamp = value
                false
            } else if (pairingStamp == value) {
                false
            } else {
                pairingStamp = value
                true
            }
        }
        if (changed) closeAll()
    }

    /** Invalidates sessions immediately and performs binder work off the UI thread. */
    fun closeAll() {
        val retiring = synchronized(stateLock) {
            generation += 1
            reservedOwners.clear()
            sessions.values.toList().also { values ->
                values.forEach { session ->
                    if (session.retired.compareAndSet(false, true)) closingIsolates += 1
                }
                sessions.clear()
            }
        }
        retiring.forEach { it.resources.close() }
        maintenanceScope.launch {
            retiring.forEach { session -> closeRetired(session) }
        }
    }

    /** Activity teardown permanently closes this bridge's shared sandbox. */
    fun dispose() {
        if (closed) return
        closeAll()
        closed = true
        maintenanceScope.launch {
            sandboxLock.withLock {
                val current = sandbox
                sandbox = null
                if (current != null) runCatching { current.close() }
            }
            maintenanceScope.cancel()
        }
    }

    private suspend fun requireSupportedSandbox(): JavaScriptSandbox {
        if (!withContext(Dispatchers.IO) { JavaScriptSandbox.isSupported() }) {
            throw DocumentScriptException("SCRIPT_UNSUPPORTED", NativeI18n.text("JavaScriptEngine is unavailable on this device."))
        }
        val connected = connectedSandbox()
        val missing = withContext(Dispatchers.IO) { missingRequiredFeatures(connected) }
        if (missing.isNotEmpty()) {
            throw DocumentScriptException(
                "SCRIPT_UNSUPPORTED",
                NativeI18n.text("JavaScriptEngine is missing required features: {0}.", missing.joinToString()),
            )
        }
        return connected
    }

    private suspend fun connectedSandbox(): JavaScriptSandbox = withContext(Dispatchers.IO) {
        sandboxLock.withLock {
            ensureOpen()
            sandbox?.let { return@withLock it }
            val created = await(JavaScriptSandbox.createConnectedInstanceAsync(appContext))
            if (closed) {
                runCatching { created.close() }
                throw DocumentScriptException("SCRIPT_CLOSED", "The document script engine is closed.")
            }
            sandbox = created
            created
        }
    }

    private fun missingRequiredFeatures(value: JavaScriptSandbox): List<String> = REQUIRED_FEATURES
        .filterNot(value::isFeatureSupported)

    private fun unavailable(reason: String): Map<String, Any> = mapOf("supported" to false, "reason" to reason)

    private fun requireSession(id: Int, owner: String, contextId: String?): Session = synchronized(stateLock) {
        ensureOpenLocked()
        val session = sessions[id]
            ?: throw DocumentScriptException("SCRIPT_CLOSED", "The document script isolate is unavailable.")
        if (session.owner != owner) {
            throw DocumentScriptException("SCRIPT_OWNER", "The document script owner does not match.")
        }
        val requestedContext = contextId ?: ContextRegistry.PRIMARY_CONTEXT_ID
        if (session.contextId != requestedContext) {
            throw DocumentScriptException("SCRIPT_OWNER", "The document script context does not match.")
        }
        if (session.retired.get()) {
            throw DocumentScriptException("SCRIPT_CLOSED", "The document script isolate is unavailable.")
        }
        session
    }

    private fun ensureSessionActive(session: Session) {
        synchronized(stateLock) {
            ensureOpenLocked()
            if (session.generation != generation ||
                (contextGenerations[session.contextId] ?: 0L) != session.contextGeneration ||
                sessions[session.id] !== session || session.retired.get()
            ) {
                throw DocumentScriptException("SCRIPT_CLOSED", "The document script isolate is unavailable.")
            }
        }
    }

    private fun onIsolateTerminated(session: Session): Boolean {
        val retired = synchronized(stateLock) {
            if (sessions[session.id] === session && session.retired.compareAndSet(false, true)) {
                sessions.remove(session.id)
                closingIsolates += 1
                true
            } else {
                false
            }
        }
        if (retired) session.resources.close()
        return retired
    }

    private suspend fun retireAndClose(session: Session) {
        val shouldClose = synchronized(stateLock) {
            val first = session.retired.compareAndSet(false, true)
            if (sessions[session.id] === session) sessions.remove(session.id)
            if (first) closingIsolates += 1
            first
        }
        session.resources.close()
        if (shouldClose) closeRetired(session)
    }

    private suspend fun closeRetired(session: Session) {
        try {
            withContext(NonCancellable + Dispatchers.IO) { session.isolate.close() }
        } catch (_: Exception) {
            // A crashed or already-closed isolate needs no further cleanup.
        } finally {
            synchronized(stateLock) { closingIsolates = (closingIsolates - 1).coerceAtLeast(0) }
        }
    }

    private suspend fun resetSandboxAfterCrash(dead: JavaScriptSandbox) {
        var retiring: List<Session> = emptyList()
        sandboxLock.withLock {
            if (sandbox !== dead) return
            synchronized(stateLock) {
                generation += 1
                reservedOwners.clear()
                retiring = sessions.values.toList()
                sessions.clear()
                retiring.forEach { it.retired.set(true) }
            }
            retiring.forEach { it.resources.close() }
            sandbox = null
            withContext(NonCancellable + Dispatchers.IO) { runCatching { dead.close() } }
        }
        retiring.forEach { session ->
            synchronized(stateLock) { closingIsolates += 1 }
            closeRetired(session)
        }
    }

    private fun nextAvailableIdLocked(): Int {
        repeat(Int.MAX_VALUE) {
            val candidate = nextId
            nextId = if (nextId == Int.MAX_VALUE) 1 else nextId + 1
            if (candidate !in sessions && candidate !in reservedIds) return candidate
        }
        throw DocumentScriptException("SCRIPT_CAPACITY", "No document script isolate identifiers are available.")
    }

    private fun validateOwner(owner: String) {
        if (owner.isBlank() || owner.length > MAX_OWNER_CHARS) {
            throw DocumentScriptException("SCRIPT_OWNER", "The document script owner is invalid.")
        }
    }

    private fun validateSource(source: String) {
        if (source.length > MAX_VALUE_BYTES || source.toByteArray(StandardCharsets.UTF_8).size > MAX_VALUE_BYTES) {
            throw DocumentScriptException("SCRIPT_LIMIT", "JavaScript source exceeds 4 MiB.")
        }
    }

    private fun ensureOpen() {
        if (closed) throw DocumentScriptException("SCRIPT_CLOSED", "The document script engine is closed.")
    }

    private fun ensureOpenLocked() = ensureOpen()

    private suspend fun closeIsolate(isolate: JavaScriptIsolate) {
        withContext(NonCancellable + Dispatchers.IO) { runCatching { isolate.close() } }
    }

    private fun engineFailure(error: Throwable): DocumentScriptException {
        val cause = unwrap(error)
        return when (cause) {
            is DocumentScriptException -> cause
            is SandboxUnsupportedException -> DocumentScriptException("SCRIPT_UNSUPPORTED", NativeI18n.text("JavaScriptEngine is unavailable on this device."))
            is SandboxDeadException -> DocumentScriptException("SCRIPT_ENGINE", NativeI18n.text("The JavaScript sandbox stopped unexpectedly."))
            else -> DocumentScriptException("SCRIPT_EVALUATION", cause.message ?: NativeI18n.text("JavaScript evaluation failed."))
        }
    }

    private fun unwrap(error: Throwable): Throwable {
        var current = error
        while (current is ExecutionException && current.cause != null) current = current.cause!!
        return current
    }

    private suspend fun <T> await(future: ListenableFuture<T>): T = suspendCancellableCoroutine { continuation ->
        future.addListener({
            if (!continuation.isActive) return@addListener
            try {
                continuation.resume(future.get())
            } catch (error: ExecutionException) {
                continuation.resumeWithException(error.cause ?: error)
            } catch (error: Throwable) {
                continuation.resumeWithException(error)
            }
        }, DIRECT_EXECUTOR)
        continuation.invokeOnCancellation { future.cancel(true) }
    }

    private companion object {
        const val MAX_ISOLATES = 4
        const val MAX_OWNER_CHARS = 256
        const val MAX_DOCUMENT_URL_CHARS = 8192
        const val MAX_VALUE_BYTES = 4 * 1024 * 1024
        const val MAX_HEAP_BYTES = 128L * 1024L * 1024L
        const val EVALUATION_TIMEOUT_MS = 2_000L
        val DIRECT_EXECUTOR = Executor { command -> command.run() }
        val REQUIRED_FEATURES = listOf(
            JavaScriptSandbox.JS_FEATURE_ISOLATE_TERMINATION,
            JavaScriptSandbox.JS_FEATURE_ISOLATE_MAX_HEAP_SIZE,
            JavaScriptSandbox.JS_FEATURE_EVALUATE_WITHOUT_TRANSACTION_LIMIT,
        )
    }
}
