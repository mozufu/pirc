package org.mozufu.pirc.scripts

import android.content.Context
import androidx.javascriptengine.IsolateStartupParameters
import androidx.javascriptengine.IsolateTerminatedException
import androidx.javascriptengine.JavaScriptIsolate
import androidx.javascriptengine.JavaScriptSandbox
import androidx.javascriptengine.SandboxDeadException
import androidx.javascriptengine.TerminationInfo
import com.google.common.util.concurrent.ListenableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** A failure that Dart sees as the error [code]. */
class ScriptFailure(val code: String, message: String) : Exception(message)

/**
 * The JavaScript engine that runs document scripts. [SandboxScriptEngine] is the real one
 * (`androidx.javascriptengine`, a separate sandboxed process); tests use a fake, because the
 * sandbox does not run in JVM unit tests.
 */
interface ScriptEngine {
    /** Null when the engine can run document scripts, else why not. */
    fun unsupportedReason(): String?

    /** Whether an isolate can load the packaged Canvas text engine (WebAssembly). */
    fun canvasTextSupported(): Boolean

    /** A new isolate with its own heap: nothing is shared with other documents. */
    fun createIsolate(): ScriptIsolate

    /** Closes the engine and every isolate. */
    fun close()
}

interface ScriptIsolate {
    /** Runs [source] and returns its string result; [ScriptFailure] on error or timeout. */
    fun evaluate(source: String, timeoutMillis: Long): String

    /** Hands [bytes] to the script as named data (`android.consumeNamedDataAsArrayBuffer`). */
    fun provideData(name: String, bytes: ByteArray)

    /** [callback] runs once when the isolate ends on its own (crash or memory limit). */
    fun onTerminated(callback: (sandboxDead: Boolean) -> Unit)

    fun close()
}

/** The `androidx.javascriptengine` sandbox, connected on first use. */
class SandboxScriptEngine(context: Context) : ScriptEngine {
    private val appContext = context.applicationContext
    private val lock = Any()
    private var sandbox: JavaScriptSandbox? = null
    private var connecting: ListenableFuture<JavaScriptSandbox>? = null
    @Volatile private var closed = false

    override fun unsupportedReason(): String? {
        if (closed) return "The script engine is closed."
        if (!JavaScriptSandbox.isSupported()) return "JavaScriptEngine is unavailable on this device."
        val missing = REQUIRED_FEATURES.filterNot(connected()::isFeatureSupported)
        return if (missing.isEmpty()) null else "JavaScriptEngine is missing ${missing.joinToString()}."
    }

    override fun canvasTextSupported(): Boolean =
        android.os.Build.VERSION.SDK_INT >= 31 && CANVAS_FEATURES.all(connected()::isFeatureSupported)

    override fun createIsolate(): ScriptIsolate {
        val engine = connected()
        val startup = IsolateStartupParameters().apply {
            setMaxHeapSizeBytes(MAX_HEAP_BYTES)
            setMaxEvaluationReturnSizeBytes(DocumentScripts.MAX_VALUE_BYTES)
        }
        return try {
            SandboxIsolate(engine.createIsolate(startup)) { dropSandbox(engine) }
        } catch (error: SandboxDeadException) {
            dropSandbox(engine)
            throw ScriptFailure("SCRIPT_ENGINE", "The JavaScript sandbox stopped.")
        }
    }

    /** Never waits: a connection still starting is closed once it is made. */
    override fun close() {
        val (current, pending) = synchronized(lock) {
            closed = true
            (sandbox to connecting).also {
                sandbox = null
                connecting = null
            }
        }
        current?.let { runCatching { it.close() } }
        pending?.addListener({ runCatching { pending.get().close() } }, DIRECT)
    }

    /**
     * The lock is held only to read and set fields, never across the wait for the sandbox.
     * A connection is used only while it is still [connecting]: one that a wait gave up on
     * is closed when it is made, by the listener of the thread that gave up.
     */
    private fun connected(): JavaScriptSandbox {
        val pending = synchronized(lock) {
            if (closed) throw ScriptFailure("SCRIPT_CLOSED", "The script engine is closed.")
            sandbox?.let { return it }
            connecting ?: JavaScriptSandbox.createConnectedInstanceAsync(appContext).also { connecting = it }
        }
        val created = try {
            pending.get(CONNECT_SECONDS, TimeUnit.SECONDS)
        } catch (error: Exception) {
            val abandoned = synchronized(lock) {
                (connecting === pending).also { if (it) connecting = null }
            }
            // A sandbox that connects after the wait is never used, so it must not stay bound.
            if (abandoned) pending.addListener({ runCatching { pending.get().close() } }, DIRECT)
            throw ScriptFailure("SCRIPT_UNSUPPORTED", "JavaScriptEngine could not start on this device.")
        }
        synchronized(lock) {
            // Another thread that waited for the same connection already took it.
            if (sandbox === created) return created
            if (closed) {
                runCatching { created.close() }
                throw ScriptFailure("SCRIPT_CLOSED", "The script engine is closed.")
            }
            // Another wait gave up on this connection; its listener closes it.
            if (connecting !== pending) {
                throw ScriptFailure("SCRIPT_UNSUPPORTED", "JavaScriptEngine could not start on this device.")
            }
            connecting = null
            sandbox = created
        }
        return created
    }

    /** A dead sandbox is replaced on the next use; its isolates are already gone. */
    private fun dropSandbox(dead: JavaScriptSandbox) {
        synchronized(lock) {
            if (sandbox === dead) sandbox = null
        }
        runCatching { dead.close() }
    }

    private class SandboxIsolate(
        private val isolate: JavaScriptIsolate,
        private val onSandboxDead: () -> Unit,
    ) : ScriptIsolate {
        override fun evaluate(source: String, timeoutMillis: Long): String {
            val future = isolate.evaluateJavaScriptAsync(source)
            return try {
                future.get(timeoutMillis, TimeUnit.MILLISECONDS)
            } catch (_: TimeoutException) {
                future.cancel(true)
                throw ScriptFailure("SCRIPT_TIMEOUT", "The script ran longer than $timeoutMillis ms.")
            } catch (error: ExecutionException) {
                when (val cause = error.cause) {
                    is SandboxDeadException -> {
                        onSandboxDead()
                        throw ScriptFailure("SCRIPT_ENGINE", "The JavaScript sandbox stopped.")
                    }
                    is IsolateTerminatedException ->
                        throw ScriptFailure("SCRIPT_CLOSED", "The document script stopped.")
                    else -> throw ScriptFailure("SCRIPT_EVALUATION", cause?.message ?: "The script failed.")
                }
            }
        }

        override fun provideData(name: String, bytes: ByteArray) {
            isolate.provideNamedData(name, bytes)
        }

        override fun onTerminated(callback: (Boolean) -> Unit) {
            isolate.addOnTerminatedCallback(DIRECT) { info ->
                val dead = info.status == TerminationInfo.STATUS_SANDBOX_DEAD
                if (dead) onSandboxDead()
                callback(dead)
            }
        }

        override fun close() {
            runCatching { isolate.close() }
        }
    }

    private companion object {
        const val CONNECT_SECONDS = 10L
        const val MAX_HEAP_BYTES = 128L * 1024L * 1024L
        val DIRECT = Executor { it.run() }
        val REQUIRED_FEATURES = listOf(
            JavaScriptSandbox.JS_FEATURE_ISOLATE_TERMINATION,
            JavaScriptSandbox.JS_FEATURE_ISOLATE_MAX_HEAP_SIZE,
            JavaScriptSandbox.JS_FEATURE_EVALUATE_WITHOUT_TRANSACTION_LIMIT,
        )
        val CANVAS_FEATURES = listOf(
            JavaScriptSandbox.JS_FEATURE_WASM_COMPILATION,
            JavaScriptSandbox.JS_FEATURE_PROVIDE_CONSUME_ARRAY_BUFFER,
            JavaScriptSandbox.JS_FEATURE_PROMISE_RETURN,
        )
    }
}
