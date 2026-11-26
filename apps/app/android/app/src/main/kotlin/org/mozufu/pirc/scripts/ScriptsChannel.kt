package org.mozufu.pirc.scripts

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import org.mozufu.pirc.PlatformFeature
import org.mozufu.pirc.fonts.CanvasTextFonts
import org.mozufu.pirc.mainThreadExecutor

/**
 * `org.mozufu.pirc/scripts`: scripts of documents that come from a message or a tool result
 * (plans/roadmap.md M8 step 6). They run with an opaque origin in `androidx.javascriptengine`.
 * - `capabilities` → `{supported, reason?, canvasText?}`
 * - `open {owner}` → `{id, origin: "null"}`: a new isolate with its own storage and cookies
 * - `runtime {id, owner}`: runs the packaged document runtime in the isolate
 * - `canvasText {id, owner, families, sample}` → `{value, fontBytes}`: loads the Canvas text
 *   engine and the system fonts into the isolate (the font files never reach Dart)
 * - `evaluate {id, owner, source}` → `{value}` (at most 4 MiB each way, 2 seconds)
 * - `storage {id, owner, operations}` → `{local: {…}, session: {…}}`
 * - `cookies {id, owner, writes: [line]}` → `{cookie}`
 * - `resource {id, owner, request: {id, url, method?, headers?: [[name, value]], bodyBytes?,
 *   kind: fetch|script|module|stylesheet, mode?: cors|no-cors, redirect?}}` → the response
 *   `{status, statusText, url, headers, bodyBytes, type, redirected, mimeType, charset,
 *   originClean}`, fetched without credentials; `resourceCancel {id, owner, requestId}`
 * - `media {url, requestId}` → `{bytes, mimeType}`: a media element the user tapped;
 *   `mediaCancel {requestId}`
 * - `close {id, owner}`; `closeAll` (unpairing)
 *
 * Errors: `INVALID` (bad arguments) and the [ScriptFailure] codes: `SCRIPT_UNSUPPORTED`,
 * `SCRIPT_CLOSED`, `SCRIPT_OWNER`, `SCRIPT_CAPACITY`, `SCRIPT_TIMEOUT`, `SCRIPT_LIMIT`,
 * `SCRIPT_EVALUATION`, `SCRIPT_ENGINE`, `STORAGE_QUOTA` and `RESOURCE`.
 *
 * Nothing here holds the device token or the Gateway's address: this feature is built without
 * the credential store, and its HTTP client has no cookies and no Authorization header.
 *
 * Calls run on three executors, so one kind of work never waits behind another: [work] for
 * script work (`open`, `runtime`, `canvasText`, `evaluate`, `storage`, `cookies`), [network]
 * for `resource` and `media`, and [control] for the quick calls (`capabilities`, `close`,
 * `closeAll` and the cancels). `close` and `closeAll` are never refused: when [control] is
 * full, they run on the calling thread.
 */
class ScriptsChannel(
    private val scripts: DocumentScripts,
    private val work: Executor = boundedExecutor(MAX_THREADS),
    private val network: Executor = boundedExecutor(NETWORK_THREADS),
    private val control: Executor = boundedExecutor(CONTROL_THREADS, CONTROL_QUEUED),
    private val reply: Executor = mainThreadExecutor(),
) : PlatformFeature {
    override val name = "scripts"

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val action: () -> Any? = when (call.method) {
            "capabilities" -> ({ scripts.capabilities() })
            "open" -> ({ scripts.open(owner(call)) })
            "runtime" -> ({ scripts.loadRuntime(id(call), owner(call)); null })
            "canvasText" -> ({
                val families = (call.argument<List<*>>("families") ?: emptyList<Any?>()).map {
                    it as? String ?: throw IllegalArgumentException("families must be strings")
                }
                val sample = call.argument<String>("sample") ?: ""
                CanvasTextFonts.checkRequest(families, sample)
                scripts.canvasText(id(call), owner(call), families, sample)
            })
            "evaluate" -> ({
                mapOf("value" to scripts.evaluate(id(call), owner(call), string(call, "source")))
            })
            "storage" -> ({
                scripts.storage(id(call), owner(call), maps(call.argument<List<*>>("operations")))
            })
            "cookies" -> ({
                val writes = (call.argument<List<*>>("writes") ?: emptyList<Any?>()).map {
                    it as? String ?: throw IllegalArgumentException("writes must be strings")
                }
                scripts.cookies(id(call), owner(call), writes)
            })
            "resource" -> ({
                val raw = call.argument<Map<*, *>>("request") ?: throw IllegalArgumentException("request is required")
                val requestId = raw["id"] as? String ?: throw IllegalArgumentException("request.id is required")
                scripts.resource(id(call), owner(call), requestId, parseResourceRequest(raw))
            })
            "resourceCancel" -> ({ scripts.cancelResource(id(call), owner(call), string(call, "requestId")); null })
            "media" -> ({ scripts.media(string(call, "url"), string(call, "requestId")) })
            "mediaCancel" -> ({ scripts.cancelMedia(string(call, "requestId")); null })
            "close" -> ({ scripts.close(id(call), owner(call)); null })
            "closeAll" -> ({ scripts.closeAll(); null })
            else -> {
                result.notImplemented()
                return
            }
        }
        val task = Runnable {
            val outcome = runCatching(action)
            reply.execute {
                outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = {
                        val code = when (it) {
                            is ScriptFailure -> it.code
                            is IllegalArgumentException, is ClassCastException -> "INVALID"
                            else -> "SCRIPT_ENGINE"
                        }
                        result.error(code, it.message ?: it.javaClass.simpleName, null)
                    },
                )
            }
        }
        val executor = when (call.method) {
            "resource", "media" -> network
            "capabilities", "close", "closeAll", "resourceCancel", "mediaCancel" -> control
            else -> work
        }
        try {
            executor.execute(task)
        } catch (_: RejectedExecutionException) {
            // Closing does not block, and a refused close would leave the sessions running.
            if (call.method == "close" || call.method == "closeAll") {
                task.run()
            } else {
                result.error("SCRIPT_CAPACITY", "Too many script calls at once.", null)
            }
        }
    }

    override fun detach() {
        scripts.dispose()
        for (executor in listOf(work, network, control)) (executor as? ExecutorService)?.shutdown()
    }

    private fun id(call: MethodCall): Int =
        call.argument<Number>("id")?.toInt() ?: throw IllegalArgumentException("id is required")

    private fun owner(call: MethodCall): String = string(call, "owner")

    private fun string(call: MethodCall, name: String): String =
        call.argument<Any?>(name) as? String ?: throw IllegalArgumentException("$name must be a string")

    private fun maps(values: List<*>?): List<Map<*, *>> = (values ?: emptyList<Any?>()).map {
        it as? Map<*, *> ?: throw IllegalArgumentException("operations must be maps")
    }

    companion object {
        /** Threads for script work. Network requests never use them. */
        const val MAX_THREADS = 16

        /**
         * Threads for network requests: every document at its cap of
         * [ScriptResources.MAX_IN_FLIGHT] requests, media at the same cap, and 2 more threads
         * that refuse the calls over a cap. So the requests of one document, even when they
         * hang, never make another document or a tapped media element wait for a thread.
         */
        const val NETWORK_THREADS = (DocumentScripts.MAX_SESSIONS + 1) * ScriptResources.MAX_IN_FLIGHT + 2

        /** Threads for the quick calls; `capabilities` can wait for the sandbox to connect. */
        const val CONTROL_THREADS = 4
        private const val MAX_QUEUED = 256
        private const val CONTROL_QUEUED = 64

        /** At most [threads] threads and [queued] waiting calls; more are refused. */
        fun boundedExecutor(threads: Int, queued: Int = MAX_QUEUED): ExecutorService = ThreadPoolExecutor(
            threads, threads, 30, TimeUnit.SECONDS, LinkedBlockingQueue(queued),
        ).apply { allowCoreThreadTimeOut(true) }

        /** The scripts feature of the app; the runtime and the Canvas engine come from the APK. */
        fun create(context: Context): ScriptsChannel {
            val app = context.applicationContext
            fun asset(name: String): ByteArray = app.assets.open("scripts/$name").use { it.readBytes() }
            val canvas = object : CanvasTextSource {
                override fun wasm() = asset("document-canvas-text.wasm")
                override fun glue() = String(asset("document-canvas-text.js"), Charsets.UTF_8)
                override fun collect(families: List<String>, sample: String) = CanvasTextFonts.collect(families, sample)
            }
            return ScriptsChannel(
                DocumentScripts(
                    engine = SandboxScriptEngine(app),
                    runtimeSource = { String(asset("document-script-runtime.js"), Charsets.UTF_8) },
                    canvasText = if (CanvasTextFonts.supported()) canvas else null,
                ),
            )
        }

        /** Reads a `resource` request; a script cannot ask for an image (images wait for a tap). */
        fun parseResourceRequest(raw: Map<*, *>): ScriptResources.ResourceRequest {
            fun optional(name: String): String? = raw[name]?.let {
                it as? String ?: throw IllegalArgumentException("request.$name must be a string")
            }
            val kind = when (optional("kind") ?: "fetch") {
                "fetch" -> ScriptResources.Kind.FETCH
                "script" -> ScriptResources.Kind.SCRIPT
                "module" -> ScriptResources.Kind.MODULE
                "stylesheet" -> ScriptResources.Kind.STYLESHEET
                "image" -> throw ScriptFailure("RESOURCE", "Remote images in a message load only after a tap.")
                else -> throw IllegalArgumentException("Unsupported resource kind")
            }
            val defaultMode = if (kind == ScriptResources.Kind.FETCH || kind == ScriptResources.Kind.MODULE) "cors" else "no-cors"
            val mode = when (optional("mode") ?: defaultMode) {
                "cors" -> ScriptResources.Mode.CORS
                "no-cors" -> ScriptResources.Mode.NO_CORS
                else -> throw IllegalArgumentException("Unsupported request mode")
            }
            val redirect = when (optional("redirect") ?: "follow") {
                "follow" -> ScriptResources.Redirect.FOLLOW
                "error" -> ScriptResources.Redirect.ERROR
                "manual" -> ScriptResources.Redirect.MANUAL
                else -> throw IllegalArgumentException("Unsupported redirect mode")
            }
            val headers = (raw["headers"] as? List<*> ?: emptyList<Any?>()).map { pair ->
                val fields = pair as? List<*> ?: throw IllegalArgumentException("request.headers must be pairs")
                require(fields.size == 2) { "request.headers must be pairs" }
                (fields[0] as? String ?: throw IllegalArgumentException("Header names must be strings")) to
                    (fields[1] as? String ?: throw IllegalArgumentException("Header values must be strings"))
            }
            val body = raw["bodyBytes"]?.let { it as? ByteArray ?: throw IllegalArgumentException("request.bodyBytes must be bytes") }
            return ScriptResources.ResourceRequest(
                url = optional("url") ?: throw IllegalArgumentException("request.url is required"),
                method = optional("method") ?: "GET",
                headers = headers,
                body = body,
                kind = kind,
                mode = mode,
                redirect = redirect,
            )
        }
    }
}
