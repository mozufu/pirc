package org.mozufu.pirc.scripts

import java.nio.charset.StandardCharsets
import java.util.IdentityHashMap
import java.util.concurrent.atomic.AtomicBoolean

/** The packaged Canvas text engine and the system fonts it draws with (carry-over of step 7). */
interface CanvasTextSource {
    fun wasm(): ByteArray

    /** The packaged script that loads [wasm] in the isolate (`__pircInitializeCanvasText`). */
    fun glue(): String

    /** As `CanvasTextFonts.collect`: resources with `bytes`, and matches. */
    fun collect(families: List<String>, sample: String): Map<String, Any?>
}

/**
 * The script sessions of message documents: one isolate per document, ported from the old
 * app's `NativeDocumentScripts.kt` without its Gateway coupling.
 *
 * A message document runs with an opaque origin. Each session gets its own isolate, its own
 * [DocumentStorage] and [DocumentCookies], created here when the document opens and dropped
 * when it closes; Dart cannot name another document's storage, because the stores have no key
 * outside the session. Nothing in this class can reach the device token or the Gateway.
 */
class DocumentScripts(
    private val engine: ScriptEngine,
    private val resources: ScriptResources = ScriptResources(),
    private val runtimeSource: () -> String? = { null },
    private val canvasText: CanvasTextSource? = null,
    private val cookieClock: () -> Long = System::currentTimeMillis,
) {
    private class Session(
        val id: Int,
        val owner: String,
        val isolate: ScriptIsolate,
        val generation: Long,
    ) {
        val storage = DocumentStorage()
        val cookies = DocumentCookies()
        val calls = ScriptResources.Calls()
        val evaluation = Any()
        val retired = AtomicBoolean(false)
        val canvasPrepared = AtomicBoolean(false)
    }

    private val lock = Any()
    private val sessions = mutableMapOf<Int, Session>()
    private val opening = mutableSetOf<String>()
    private val mediaCalls = ScriptResources.Calls()
    private var nextId = 1
    private var generation = 0L
    @Volatile private var disposed = false

    fun capabilities(): Map<String, Any?> {
        val reason = runCatching { engine.unsupportedReason() }.getOrElse { it.message ?: "unavailable" }
        return if (reason != null) {
            mapOf("supported" to false, "reason" to reason)
        } else {
            mapOf("supported" to true, "canvasText" to (canvasText != null && engine.canvasTextSupported()))
        }
    }

    /** Opens an isolate for one message document. Returns `{id, origin: "null"}`. */
    fun open(owner: String): Map<String, Any?> {
        validateOwner(owner)
        engine.unsupportedReason()?.let { throw ScriptFailure("SCRIPT_UNSUPPORTED", it) }
        val startGeneration = synchronized(lock) {
            ensureOpen()
            if (sessions.values.any { it.owner == owner } || owner in opening) {
                throw ScriptFailure("SCRIPT_OWNER", "This document already has a script session.")
            }
            if (sessions.size + opening.size >= MAX_SESSIONS) {
                throw ScriptFailure("SCRIPT_CAPACITY", "At most $MAX_SESSIONS documents can run scripts at once.")
            }
            opening += owner
            generation
        }
        var isolate: ScriptIsolate? = null
        try {
            val created = engine.createIsolate()
            isolate = created
            val session = synchronized(lock) {
                opening -= owner
                if (disposed || generation != startGeneration) {
                    throw ScriptFailure("SCRIPT_CLOSED", "The script sessions closed while this one opened.")
                }
                Session(nextFreeId(), owner, created, startGeneration).also { sessions[it.id] = it }
            }
            created.onTerminated { sandboxDead -> if (sandboxDead) closeAll() else retire(session) }
            return mapOf("id" to session.id, "origin" to "null")
        } catch (error: Throwable) {
            synchronized(lock) { opening -= owner }
            isolate?.close()
            throw error
        }
    }

    /**
     * Runs the packaged document runtime in the session's isolate. It is read from the APK
     * here, so Dart never holds it and the Web build never ships it.
     */
    fun loadRuntime(id: Int, owner: String) {
        val session = session(id, owner)
        val source = runtimeSource() ?: throw ScriptFailure("SCRIPT_UNSUPPORTED", "The document runtime is not packaged.")
        synchronized(session.evaluation) {
            ensureActive(session)
            try {
                session.isolate.evaluate(source, RUNTIME_TIMEOUT_MS)
            } catch (failure: ScriptFailure) {
                retire(session)
                throw failure
            }
        }
    }

    fun evaluate(id: Int, owner: String, source: String): String {
        val session = session(id, owner)
        if (source.length > MAX_VALUE_BYTES || source.toByteArray(StandardCharsets.UTF_8).size > MAX_VALUE_BYTES) {
            throw ScriptFailure("SCRIPT_LIMIT", "The script source is larger than 4 MiB.")
        }
        synchronized(session.evaluation) {
            ensureActive(session)
            val value = try {
                session.isolate.evaluate(source, EVALUATION_TIMEOUT_MS)
            } catch (failure: ScriptFailure) {
                when (failure.code) {
                    // A runaway script loses its isolate, as in the old app.
                    "SCRIPT_TIMEOUT", "SCRIPT_CLOSED" -> retire(session)
                    "SCRIPT_ENGINE" -> closeAll()
                }
                throw failure
            }
            if (value.toByteArray(StandardCharsets.UTF_8).size > MAX_VALUE_BYTES) {
                throw ScriptFailure("SCRIPT_LIMIT", "The script result is larger than 4 MiB.")
            }
            return value
        }
    }

    /** Applies storage operations of this document only; see [DocumentStorage.apply]. */
    fun storage(id: Int, owner: String, operations: List<Map<*, *>>): Map<String, Any?> =
        session(id, owner).storage.apply(operations)

    /** Applies `document.cookie` writes of this document only and returns `{cookie}`. */
    fun cookies(id: Int, owner: String, writes: List<String>): Map<String, Any?> =
        mapOf("cookie" to session(id, owner).cookies.write(writes))

    /** A network request of this document's script, without credentials. */
    fun resource(id: Int, owner: String, requestId: String, request: ScriptResources.ResourceRequest): Map<String, Any?> {
        val session = session(id, owner)
        val response = resources.load(request, session.calls, requestId)
        ensureActive(session)
        return response
    }

    fun cancelResource(id: Int, owner: String, requestId: String) {
        val session = synchronized(lock) { sessions[id] } ?: return
        if (session.owner != owner) throw ScriptFailure("SCRIPT_OWNER", "The document does not match.")
        session.calls.cancel(requestId)
    }

    /** The bytes of a media element after the user tapped it (no session, no credentials). */
    fun media(url: String, requestId: String): Map<String, Any?> {
        ensureOpen()
        return resources.media(url, mediaCalls, requestId)
    }

    fun cancelMedia(requestId: String) = mediaCalls.cancel(requestId)

    /**
     * Loads the Canvas text engine and the system fonts into the document's isolate and runs
     * its set-up there; returns `{value, fontBytes}` with the set-up's JSON result. The font
     * files stay in Kotlin: they go straight into the isolate, each shared file once (a TTC
     * collection serves several faces), and never reach Dart.
     */
    fun canvasText(id: Int, owner: String, families: List<String>, sample: String): Map<String, Any?> {
        val source = canvasText ?: throw ScriptFailure("SCRIPT_UNSUPPORTED", "Canvas text is unavailable.")
        if (!engine.canvasTextSupported()) throw ScriptFailure("SCRIPT_UNSUPPORTED", "Canvas text is unavailable.")
        val session = session(id, owner)
        synchronized(session.evaluation) {
            ensureActive(session)
            if (!session.canvasPrepared.compareAndSet(false, true)) {
                throw ScriptFailure("SCRIPT_LIMIT", "Canvas text was already prepared for this document.")
            }
            val collected = source.collect(families, sample)
            val wasm = source.wasm()
            require(wasm.size in 1..MAX_WASM_BYTES) { "Invalid packaged Canvas text engine" }
            val names = deduplicate(collected["resources"] as List<*>)
            ensureActive(session)
            try {
                session.isolate.provideData(WASM_NAME, wasm)
                for ((bytes, name) in names.first) session.isolate.provideData(name, bytes)
                val resources = mapOf("wasmName" to WASM_NAME, "resources" to names.second, "matches" to collected["matches"])
                session.isolate.evaluate(source.glue(), RUNTIME_TIMEOUT_MS)
                val prepared = session.isolate.evaluate(
                    "__pircInitializeCanvasText(${org.json.JSONObject.wrap(resources)})",
                    RUNTIME_TIMEOUT_MS,
                )
                return mapOf("value" to prepared, "fontBytes" to names.first.keys.sumOf { it.size.toLong() })
            } catch (failure: ScriptFailure) {
                // As for evaluate: a stuck or stopped isolate is not used again.
                when (failure.code) {
                    "SCRIPT_TIMEOUT", "SCRIPT_CLOSED", "SCRIPT_EVALUATION" -> retire(session)
                    "SCRIPT_ENGINE" -> closeAll()
                }
                throw failure
            }
        }
    }

    fun close(id: Int, owner: String) = retire(session(id, owner))

    /** Closes every session and cancels every request (unpairing, or a dead sandbox). */
    fun closeAll() {
        val retiring = synchronized(lock) {
            generation += 1
            sessions.values.toList().also { sessions.clear() }
        }
        // Media requests are cancelled, but media stay available for the next pairing.
        mediaCalls.cancelAll()
        retiring.forEach(::retire)
    }

    fun dispose() {
        disposed = true
        closeAll()
        mediaCalls.close()
        engine.close()
    }

    /** The number of open sessions (for tests and capacity). */
    val openCount: Int get() = synchronized(lock) { sessions.size }

    private fun retire(session: Session) {
        synchronized(lock) { if (sessions[session.id] === session) sessions.remove(session.id) }
        if (!session.retired.compareAndSet(false, true)) return
        session.calls.close()
        session.storage.clear()
        session.cookies.clear()
        session.isolate.close()
    }

    private fun session(id: Int, owner: String): Session = synchronized(lock) {
        validateOwner(owner)
        ensureOpen()
        val session = sessions[id] ?: throw ScriptFailure("SCRIPT_CLOSED", "The document script session is closed.")
        if (session.owner != owner) throw ScriptFailure("SCRIPT_OWNER", "The document does not match.")
        session
    }

    private fun ensureActive(session: Session) {
        synchronized(lock) {
            if (session.retired.get() || sessions[session.id] !== session || session.generation != generation) {
                throw ScriptFailure("SCRIPT_CLOSED", "The document script session is closed.")
            }
        }
    }

    private fun ensureOpen() {
        if (disposed) throw ScriptFailure("SCRIPT_CLOSED", "The script engine is closed.")
    }

    private fun nextFreeId(): Int {
        while (nextId in sessions) nextId = if (nextId == Int.MAX_VALUE) 1 else nextId + 1
        return nextId.also { nextId = if (it == Int.MAX_VALUE) 1 else it + 1 }
    }

    private fun validateOwner(owner: String) {
        if (owner.isBlank() || owner.length > MAX_OWNER_CHARS) {
            throw ScriptFailure("SCRIPT_OWNER", "The document owner is invalid.")
        }
    }

    companion object {
        const val MAX_SESSIONS = 4
        const val MAX_OWNER_CHARS = 256
        const val MAX_VALUE_BYTES = 4 * 1024 * 1024
        const val EVALUATION_TIMEOUT_MS = 2_000L
        const val RUNTIME_TIMEOUT_MS = 10_000L
        const val MAX_WASM_BYTES = 16 * 1024 * 1024
        const val WASM_NAME = "pirc-canvas-text-wasm"

        /**
         * Gives each distinct font file one data name. `CanvasTextFonts.collect` returns the
         * same array for every face of one file, so identity finds the shared ones.
         */
        fun deduplicate(resources: List<*>): Pair<Map<ByteArray, String>, List<Map<String, Any?>>> {
            val names = IdentityHashMap<ByteArray, String>()
            val wire = resources.map { raw ->
                val resource = raw as Map<*, *>
                val bytes = resource["bytes"] as ByteArray
                val name = names.getOrPut(bytes) { "pirc-canvas-font-${names.size}" }
                resource.entries.filter { it.key != "bytes" }.associate { it.key as String to it.value } +
                    ("dataName" to name)
            }
            return names to wire
        }
    }
}
