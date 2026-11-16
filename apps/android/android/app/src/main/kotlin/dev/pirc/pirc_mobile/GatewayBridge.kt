package dev.pirc.pirc_mobile

import android.app.Activity
import android.content.Intent
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.DragEvent
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import dev.pirc.android.core.*
import dev.pirc.android.push.PushRegistration
import dev.pirc.android.push.PushStatus
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.common.MlKitException
import com.google.android.gms.common.moduleinstall.InstallStatusListener
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
import com.google.android.gms.common.moduleinstall.ModuleInstallStatusUpdate
import org.unifiedpush.android.connector.UnifiedPush
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal class PushEnableFailure(val code: String, message: String) : Exception(message)

internal data class AttachmentPickerMimeTypes(
    val primaryType: String,
    val extraTypes: List<String>,
)

private fun parseDocumentScriptResourceRequest(value: Any?): NativeScriptResourceTransport.ResourceRequest {
    val request = value as? Map<*, *>
        ?: throw IllegalArgumentException("documentScriptResource request must be a map")
    fun string(name: String, default: String? = null): String =
        (request[name] as? String) ?: default
        ?: throw IllegalArgumentException("documentScriptResource request.$name must be a string")
    fun optionalString(name: String): String? {
        val raw = request[name] ?: return null
        return raw as? String
            ?: throw IllegalArgumentException("documentScriptResource request.$name must be a string")
    }
    val kind = when (string("kind")) {
        "fetch" -> NativeScriptResourceTransport.Kind.FETCH
        "script" -> if (optionalString("type")?.trim()?.lowercase() == "module") {
            NativeScriptResourceTransport.Kind.MODULE_SCRIPT
        } else NativeScriptResourceTransport.Kind.CLASSIC_SCRIPT
        "image" -> NativeScriptResourceTransport.Kind.IMAGE
        "stylesheet" -> NativeScriptResourceTransport.Kind.STYLESHEET
        else -> throw IllegalArgumentException("Unsupported document script resource kind")
    }
    val mode = when (string("mode", if (kind != NativeScriptResourceTransport.Kind.FETCH) "no-cors" else "cors")) {
        "cors" -> NativeScriptResourceTransport.Mode.CORS
        "no-cors" -> NativeScriptResourceTransport.Mode.NO_CORS
        "same-origin" -> NativeScriptResourceTransport.Mode.SAME_ORIGIN
        else -> throw IllegalArgumentException("Unsupported document fetch mode")
    }
    val credentials = when (string("credentials", "same-origin")) {
        "omit" -> NativeScriptResourceTransport.Credentials.OMIT
        "same-origin" -> NativeScriptResourceTransport.Credentials.SAME_ORIGIN
        "include" -> NativeScriptResourceTransport.Credentials.INCLUDE
        else -> throw IllegalArgumentException("Unsupported document credentials mode")
    }
    val redirect = when (string("redirect", "follow")) {
        "follow" -> NativeScriptResourceTransport.Redirect.FOLLOW
        "error" -> NativeScriptResourceTransport.Redirect.ERROR
        "manual" -> NativeScriptResourceTransport.Redirect.MANUAL
        else -> throw IllegalArgumentException("Unsupported document redirect mode")
    }
    val rawHeaders = request["headers"] ?: emptyList<Any>()
    val headers = (rawHeaders as? List<*>)
        ?: throw IllegalArgumentException("documentScriptResource request.headers must be a list")
    require(headers.size <= 128) { "Too many document resource request headers" }
    val parsedHeaders = headers.mapIndexed { index, pair ->
        val fields = pair as? List<*>
            ?: throw IllegalArgumentException("request.headers[$index] must be a pair")
        require(fields.size == 2) { "request.headers[$index] must contain two values" }
        val name = fields[0] as? String
            ?: throw IllegalArgumentException("request.headers[$index][0] must be a string")
        val headerValue = fields[1] as? String
            ?: throw IllegalArgumentException("request.headers[$index][1] must be a string")
        NativeScriptResourceTransport.Header(name, headerValue)
    }
    require(request["bodyBytes"] == null || request["bodyBase64"] == null) {
        "request.bodyBytes and request.bodyBase64 are mutually exclusive"
    }
    val bodyBytes = request["bodyBytes"]?.let { raw ->
        raw as? ByteArray ?: throw IllegalArgumentException("request.bodyBytes must be bytes")
    }
    val bodyBase64 = request["bodyBase64"]?.let { raw ->
        raw as? String ?: throw IllegalArgumentException("request.bodyBase64 must be a string")
    }
    require(bodyBase64 == null || bodyBase64.length <= 2_796_204) {
        "Script request body exceeds 2 MiB"
    }
    val body = bodyBytes ?: bodyBase64?.let { encoded ->
        runCatching { java.util.Base64.getDecoder().decode(encoded) }
            .getOrElse { throw IllegalArgumentException("request.bodyBase64 is invalid") }
    }
    require(body == null || body.size <= 2 * 1024 * 1024) {
        "Script request body exceeds 2 MiB"
    }
    return NativeScriptResourceTransport.ResourceRequest(
        url = string("url"),
        method = string("method", "GET"),
        headers = parsedHeaders,
        body = body,
        mode = mode,
        credentials = credentials,
        kind = kind,
        redirect = redirect,
        crossOrigin = optionalString("crossOrigin"),
        integrity = optionalString("integrity"),
        referrerPolicy = optionalString("referrerPolicy"),
        forcePreflight = request["forcePreflight"]?.let {
            it as? Boolean ?: throw IllegalArgumentException("request.forcePreflight must be boolean")
        } ?: false,
        stylesheetReferrerUrl = optionalString("stylesheetReferrerUrl"),
        moduleReferrerUrl = optionalString("moduleReferrerUrl"),
    )
}

private fun documentScriptResourceWire(
    response: NativeScriptResourceTransport.ResourceResponse,
): Map<String, Any?> = mapOf(
    "status" to response.status,
    "statusText" to response.statusText,
    "url" to response.url,
    "headers" to response.headers.entries
        .sortedBy { it.key.lowercase() }
        .map { listOf(it.key, it.value) },
    "bodyBytes" to response.body,
    "type" to response.type,
    "redirected" to response.redirected,
    "mimeType" to response.mimeType,
    "charset" to response.charset,
    "originClean" to response.originClean,
    "stylesheetReferrerPolicy" to response.stylesheetReferrerPolicy,
    "moduleReferrerPolicy" to response.moduleReferrerPolicy,
)

private class GmsBarcodeScanModuleInstaller(
    activity: Activity,
    private val scanner: com.google.mlkit.vision.codescanner.GmsBarcodeScanner,
) : BarcodeScanModuleInstaller {
    private val client = ModuleInstall.getClient(activity)

    override fun areModulesAvailable(
        onResult: (Boolean) -> Unit,
        onFailure: (Exception) -> Unit,
    ) {
        client.areModulesAvailable(scanner)
            .addOnSuccessListener { onResult(it.areModulesAvailable()) }
            .addOnFailureListener(onFailure)
    }

    override fun install(
        onInstalled: () -> Unit,
        onCancelled: () -> Unit,
        onFailure: (Exception) -> Unit,
    ): BarcodeScanCancellation {
        val terminal = AtomicBoolean(false)
        val registered = AtomicBoolean(true)
        fun installed() {
            if (terminal.compareAndSet(false, true)) onInstalled()
        }
        fun cancelled() {
            if (terminal.compareAndSet(false, true)) onCancelled()
        }
        fun failed(error: Exception) {
            if (terminal.compareAndSet(false, true)) onFailure(error)
        }

        val listener = object : InstallStatusListener {
            override fun onInstallStatusUpdated(update: ModuleInstallStatusUpdate) {
                when (update.installState) {
                    ModuleInstallStatusUpdate.InstallState.STATE_COMPLETED -> installed()
                    ModuleInstallStatusUpdate.InstallState.STATE_CANCELED -> cancelled()
                    ModuleInstallStatusUpdate.InstallState.STATE_FAILED -> failed(
                        BarcodeScanModuleInstallException(update.errorCode),
                    )
                }
            }
        }
        val request = ModuleInstallRequest.newBuilder()
            .addApi(scanner)
            .setListener(listener)
            .build()
        try {
            client.installModules(request)
                .addOnSuccessListener { response ->
                    if (response.areModulesAlreadyInstalled()) installed()
                }
                .addOnFailureListener(::failed)
        } catch (error: Exception) {
            if (registered.compareAndSet(true, false)) client.unregisterListener(listener)
            throw error
        }

        return BarcodeScanCancellation {
            if (registered.compareAndSet(true, false)) {
                client.unregisterListener(listener)
            }
        }
    }
}

private class GmsBarcodeScanStarter(
    private val scanner: com.google.mlkit.vision.codescanner.GmsBarcodeScanner,
) : BarcodeScanStarter {
    override fun start(
        onSuccess: (String?) -> Unit,
        onCancelled: () -> Unit,
        onFailure: (Exception) -> Unit,
    ) {
        scanner.startScan()
            .addOnSuccessListener { onSuccess(it.rawValue) }
            .addOnCanceledListener { onCancelled() }
            .addOnFailureListener(onFailure)
    }
}

/** Maps HTML accept hints to Android chooser filters; an unknown hint stays unfiltered. */
internal fun attachmentPickerMimeTypes(
    accept: List<String>,
    mimeForExtension: (String) -> String?,
): AttachmentPickerMimeTypes {
    val mimePattern = Regex("[a-z0-9!#&^_.+-]+/(?:\\*|[a-z0-9!#&^_.+-]+)")
    val mapped = accept.mapNotNull { raw ->
        val token = raw.trim().lowercase(java.util.Locale.ROOT)
        val candidate = if (token.startsWith('.')) {
            val extension = token.drop(1).takeIf { it.matches(Regex("[a-z0-9][a-z0-9+_-]*")) }
                ?: return@mapNotNull null
            mimeForExtension(extension)
        } else {
            token
        }
        candidate?.trim()?.lowercase(java.util.Locale.ROOT)?.takeIf(mimePattern::matches)
    }.distinct()
    return when (mapped.size) {
        0 -> AttachmentPickerMimeTypes(primaryType = "*/*", extraTypes = emptyList())
        1 -> AttachmentPickerMimeTypes(primaryType = mapped.single(), extraTypes = emptyList())
        else -> AttachmentPickerMimeTypes(primaryType = "*/*", extraTypes = mapped)
    }
}

/** Keeps event-stream teardown synchronous so a later listener cannot inherit stale cleanup. */
internal class EventStreamTeardown(
    private val cancelPendingOperations: () -> Unit,
    private val invalidateContexts: () -> Unit,
) {
    fun cancel() {
        cancelPendingOperations()
        invalidateContexts()
    }
}

/** Coordinates distributor selection and prevents duplicate native picker flows. */
internal class PushEnableCoordinator {
    private val pending = AtomicBoolean(false)

    suspend fun run(
        hasDistributor: () -> Boolean,
        captureSnapshot: suspend () -> Any,
        selectDistributor: suspend () -> Boolean,
        validateSnapshot: suspend (Any) -> Unit,
        enable: suspend (Any) -> Unit,
    ) {
        if (!pending.compareAndSet(false, true)) {
            throw PushEnableFailure("PUSH_BUSY", NativeI18n.text("A distributor picker is already open."))
        }
        try {
            if (!hasDistributor()) {
                throw PushEnableFailure(
                    "NO_DISTRIBUTOR",
                    NativeI18n.text("No UnifiedPush distributor is installed. Install one and try again."),
                )
            }
            val snapshot = captureSnapshot()
            if (!selectDistributor()) {
                if (!hasDistributor()) {
                    throw PushEnableFailure(
                        "NO_DISTRIBUTOR",
                        NativeI18n.text("No UnifiedPush distributor is installed. Install one and try again."),
                    )
                }
                throw PushEnableFailure("PUSH_CANCELLED", NativeI18n.text("No distributor was chosen."))
            }
            validateSnapshot(snapshot)
            enable(snapshot)
        } finally {
            pending.set(false)
        }
    }
}

class GatewayBridge(private val activity: MainActivity, engine: FlutterEngine) {
    private val runtime = GatewayRuntime.get(activity)
    private val recordings = RecordingPlayer(activity, engine)
    private val documentScripts = NativeDocumentScripts(activity.applicationContext)
    private val accountContextMutationLock = Mutex()
    private val firstSend = NativeFirstSend(
        java.io.File(activity.noBackupFilesDir, "first-send-v1"),
        capture = { stamp -> capturePairedApi(stamp, null) },
        validate = { stamp -> runtime.validateFirstSendStamp(stamp) },
    )
    private val htmlMedia = HtmlMediaPlayer(activity, engine, runtime, accountContextMutationLock)
    private val externalDropTargets = ExternalImageDropTargetRegistry()
    private val externalDropJobs = ConcurrentHashMap<Job, ExternalImageDropTarget>()
    private var externalDropView: FlutterView? = null
    private val pushEnableCoordinator = PushEnableCoordinator()
    private val contextGeneration = AtomicLong(0L)
    private val pushEnableJobs = ConcurrentHashMap.newKeySet<Job>()
    private var distributorPickerContinuation: CancellableContinuation<Boolean>? = null
    private val eventStreamTeardown = EventStreamTeardown(
        cancelPendingOperations = {
            pushEnableJobs.toList().forEach { it.cancel(CancellationException("Event stream closed")) }
            cancelPendingDistributorPicker()
            documentSavePicker.cancelForContextInvalidation()
            clearExternalDropTargets()
            clearProjectFileSelections()
            documentScripts.closeAll()
        },
        invalidateContexts = {
            runtime.closeAllContexts(releaseLeases = true)
        },
    )
    fun pauseMedia() {
        recordings.pauseAll()
        htmlMedia.pauseAll()
    }
    fun resumeMedia() {
        htmlMedia.resumeAll()
    }
    fun dispose() {
        contextGeneration.incrementAndGet()
        scanPreparationTimeout?.let(mainHandler::removeCallbacks)
        scanPreparationTimeout = null
        activeBarcodeScanRequestId = null
        activeBarcodeScan.also { activeBarcodeScan = null }?.dispose()
        clearExternalDropTargets()
        clearProjectFileSelections()
        documentSavePicker.dispose()
        externalDropView?.setOnDragListener(null)
        externalDropView = null
        pushEnableJobs.toList().forEach { it.cancel(CancellationException("Activity destroyed")) }
        cancelPendingDistributorPicker()
        recordings.closeAll()
        htmlMedia.dispose()
        firstSend.clear()
        documentScripts.dispose()
    }
    private val projectFileSelections = ProjectFileSelections()
    private enum class FilePickerMode { LEGACY_UPLOAD, READ_ATTACHMENTS, PROJECT_FILES }
    private data class PendingFilePicker(
        val result: MethodChannel.Result,
        val mode: FilePickerMode,
        val sessionId: String? = null,
        val workspaceId: String? = null,
        val pairingStamp: String? = null,
        val contextId: String? = null,
        val contextGeneration: Long = 0,
    )
    private data class AttachmentContents(val name: String, val mimeType: String, val bytes: ByteArray)
    private sealed class AttachmentRead {
        data class Success(val contents: AttachmentContents) : AttachmentRead()
        data class Failure(val name: String, val mimeType: String, val error: String) : AttachmentRead()
    }

    private var pendingFilePicker: PendingFilePicker? = null
    private val scanBusyGate = BarcodeScanBusyGate()
    @Volatile private var activeBarcodeScan: BarcodeScanFlow? = null
    @Volatile private var activeBarcodeScanRequestId: String? = null
    private val scanRequestSequence = AtomicLong(0L)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val documentSavePicker by lazy(LazyThreadSafetyMode.NONE) {
        DocumentSavePicker(
            activity = activity,
            runtime = runtime,
            contextGeneration = contextGeneration,
            accountContextMutationLock = accountContextMutationLock,
            mainHandler = mainHandler,
        )
    }
    private var scanPreparationTimeout: Runnable? = null
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "dev.pirc.mobile/gateway")

    private companion object {
        const val MAX_ATTACHMENT_BYTES = 8 * 1024 * 1024
        const val FILE_PICKER_REQUEST_CODE = 81
        const val SCAN_PREPARATION_TIMEOUT_MS = 30_000L
    }

    init {
        EventChannel(engine.dartExecutor.binaryMessenger, "dev.pirc.mobile/events").setStreamHandler(object: EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                runtime.listener = { sink.success(it) }
            }
            override fun onCancel(arguments: Any?) {
                contextGeneration.incrementAndGet()
                runtime.listener = null
                eventStreamTeardown.cancel()
                recordings.closeAll()
                htmlMedia.closeAll()
            }
        })
        channel.setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
            fun str(key: String) = args[key] as String
            fun optionalString(key: String): String? {
                val value = args[key] ?: return null
                return value as? String
                    ?: throw IllegalArgumentException("$key must be a string")
            }
            fun optionalBytes(key: String): ByteArray? {
                val value = args[key] ?: return null
                return value as? ByteArray
                    ?: throw IllegalArgumentException("$key must be bytes")
            }
            fun optionalBoolean(key: String): Boolean? {
                val value = args[key] ?: return null
                return value as? Boolean
                    ?: throw IllegalArgumentException("$key must be a boolean")
            }
            fun requiredLong(key: String): Long {
                val value = args[key] as? Number
                    ?: throw IllegalArgumentException("$key must be an integer")
                val longValue = value.toLong()
                require(value.toDouble() == longValue.toDouble() && longValue >= 0) {
                    "$key must be a nonnegative integer"
                }
                return longValue
            }
            fun requiredInt(key: String): Int {
                val value = requiredLong(key)
                require(value in 1..Int.MAX_VALUE.toLong()) { "$key must be a positive 32-bit integer" }
                return value.toInt()
            }
            fun optionalStringList(key: String): List<String>? {
                val value = args[key] ?: return null
                val list = value as? List<*>
                    ?: throw IllegalArgumentException("$key must be a list of strings")
                return list.mapIndexed { index, item ->
                    item as? String
                        ?: throw IllegalArgumentException("$key[$index] must be a string")
                }
            }
            val contextId = try {
                optionalString("contextId")
            } catch (e: Exception) {
                result.error("INVALID", e.message, null)
                return@setMethodCallHandler
            }
            if (contextId != null && call.method !in setOf("openContext", "closeContext", "pair", "unpair")) {
                try {
                    runtime.validateContext(contextId)
                } catch (e: ApiException) {
                    result.error("HTTP_${e.status}", e.message, mapOf("status" to e.status, "code" to e.code))
                    return@setMethodCallHandler
                }
            }
            if (call.method == "requestNotifications") {
                try { activity.permissionAccess.notifications(result) }
                catch (e: Exception) { result.error("PERMISSION", e.message, null) }
                return@setMethodCallHandler
            }
            if (call.method == "cancelScanPreparation") {
                val requestId = try {
                    optionalString("requestId")
                } catch (e: Exception) {
                    result.error("INVALID", e.message, null)
                    return@setMethodCallHandler
                }
                if (requestId.isNullOrBlank()) {
                    result.error("INVALID", "requestId is required", null)
                    return@setMethodCallHandler
                }
                val flow = activeBarcodeScan
                val cancelled = scanBusyGate.owns(requestId) &&
                    activeBarcodeScanRequestId == requestId &&
                    flow?.cancelPreparation() == true
                result.success(cancelled)
                return@setMethodCallHandler
            }
            if (call.method == "scan") {
                val requestId = try {
                    optionalString("requestId") ?: "native-scan-${scanRequestSequence.incrementAndGet()}"
                } catch (e: Exception) {
                    result.error("INVALID", e.message, null)
                    return@setMethodCallHandler
                }
                if (requestId.isBlank() || requestId.length > 128) {
                    result.error("INVALID", "requestId must contain 1 to 128 characters", null)
                    return@setMethodCallHandler
                }
                if (!scanBusyGate.tryEnter(requestId)) { result.error("SCAN_BUSY", NativeI18n.text("掃描器已開啟"), null); return@setMethodCallHandler }
                val responseCompleted = AtomicBoolean(false)
                fun failed(error: Exception) {
                    if (!responseCompleted.compareAndSet(false, true)) return
                    scanBusyGate.leave(requestId)
                    val moduleInstallError = error as? BarcodeScanModuleInstallException
                    if (moduleInstallError != null) {
                        // ModuleInstall's numeric status is useful for diagnosis; omit its message.
                        android.util.Log.e(
                            "PircScanner",
                            "scanner module install failed; errorCode=${moduleInstallError.errorCode}",
                        )
                    } else {
                        // Only class/stack locations: never log a scanned pairing link or token.
                        android.util.Log.e("PircScanner", "${error.javaClass.name} at ${error.stackTrace.take(8).joinToString()}")
                    }
                    val code = when {
                        error is BarcodeScanPreparationTimeoutException -> "SCAN_TIMEOUT"
                        (error as? MlKitException)?.errorCode == 200 -> "SCAN_DOWNLOADING"
                        (error as? MlKitException)?.errorCode == 207 -> "SCAN_UNSUPPORTED"
                        else -> "SCAN"
                    }
                    val details = moduleInstallError?.let {
                        mapOf("moduleInstallErrorCode" to it.errorCode)
                    }
                    result.error(code, NativeI18n.text("無法開啟掃描器，請稍後重試或貼上配對連結。"), details)
                }
                fun succeeded(value: String?) {
                    if (!responseCompleted.compareAndSet(false, true)) return
                    scanBusyGate.leave(requestId)
                    result.success(value)
                }
                try {
                    val options = GmsBarcodeScannerOptions.Builder()
                        .setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
                    val scanner = GmsBarcodeScanning.getClient(activity, options)
                    lateinit var flow: BarcodeScanFlow
                    flow = BarcodeScanFlow(
                        modules = GmsBarcodeScanModuleInstaller(activity, scanner),
                        scanner = GmsBarcodeScanStarter(scanner),
                    ) { outcome ->
                        if (activeBarcodeScan === flow) {
                            activeBarcodeScan = null
                            if (activeBarcodeScanRequestId == requestId) {
                                activeBarcodeScanRequestId = null
                                scanPreparationTimeout?.let(mainHandler::removeCallbacks)
                                scanPreparationTimeout = null
                            }
                        }
                        when (outcome) {
                            is BarcodeScanOutcome.Success -> succeeded(outcome.value)
                            BarcodeScanOutcome.Cancelled -> succeeded(null)
                            is BarcodeScanOutcome.Failure -> failed(outcome.error)
                        }
                    }
                    activeBarcodeScan = flow
                    activeBarcodeScanRequestId = requestId
                    val preparationTimeout = Runnable {
                        if (activeBarcodeScan === flow && activeBarcodeScanRequestId == requestId) {
                            flow.timeoutPreparation()
                        }
                    }
                    scanPreparationTimeout = preparationTimeout
                    mainHandler.postDelayed(preparationTimeout, SCAN_PREPARATION_TIMEOUT_MS)
                    flow.start()
                } catch (e: Exception) {
                    if (activeBarcodeScanRequestId == requestId) {
                        activeBarcodeScan = null
                        activeBarcodeScanRequestId = null
                        scanPreparationTimeout?.let(mainHandler::removeCallbacks)
                        scanPreparationTimeout = null
                    }
                    failed(e)
                }
                return@setMethodCallHandler
            }
            if (call.method == "saveDocument") {
                if (pendingFilePicker != null || documentSavePicker.isPending) {
                    result.error("BUSY", NativeI18n.text("A document picker is already open."), null)
                    return@setMethodCallHandler
                }
                val payload = try {
                    validateDocumentSavePayload(
                        name = optionalString("name"),
                        mimeType = optionalString("mimeType"),
                        bytes = optionalBytes("bytes"),
                    )
                } catch (e: Exception) {
                    result.error("INVALID", e.message ?: NativeI18n.text("Invalid document data"), null)
                    return@setMethodCallHandler
                }
                val pairingStamp = try {
                    optionalString("pairingStamp")
                        ?: throw IllegalArgumentException("pairingStamp is required")
                } catch (e: Exception) {
                    result.error("INVALID", e.message ?: "Invalid pairing stamp", null)
                    return@setMethodCallHandler
                }
                documentSavePicker.start(result, payload, pairingStamp, contextId)
                return@setMethodCallHandler
            }
            if (call.method == "pickProjectFiles") {
                startProjectFilePicker(args, result, contextId)
                return@setMethodCallHandler
            }
            if (call.method == "pickUpload" || call.method == "pickAttachments") {
                if (pendingFilePicker != null || documentSavePicker.isPending) { result.error("BUSY", NativeI18n.text("已有附件選擇器開啟"), null); return@setMethodCallHandler }
                val mode = if (call.method == "pickAttachments") FilePickerMode.READ_ATTACHMENTS else FilePickerMode.LEGACY_UPLOAD
                val pickerOptions: Pair<Boolean, List<String>> = try {
                    if (mode == FilePickerMode.READ_ATTACHMENTS) {
                        (optionalBoolean("multiple") ?: true) to (optionalStringList("accept") ?: emptyList())
                    } else {
                        false to emptyList<String>()
                    }
                } catch (e: Exception) {
                    result.error("INVALID", e.message, null)
                    return@setMethodCallHandler
                }
                val pending = PendingFilePicker(result, mode, if (mode == FilePickerMode.LEGACY_UPLOAD) str("sessionId") else null)
                pendingFilePicker = pending
                val picker = Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE)
                if (mode == FilePickerMode.READ_ATTACHMENTS) {
                    val mimeTypes = attachmentPickerMimeTypes(pickerOptions.second) { extension ->
                        MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
                    }
                    picker.setType(mimeTypes.primaryType)
                    if (mimeTypes.extraTypes.isNotEmpty()) {
                        picker.putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.extraTypes.toTypedArray())
                    }
                    picker.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, pickerOptions.first)
                }
                try {
                    activity.startActivityForResult(picker, FILE_PICKER_REQUEST_CODE)
                } catch (e: Exception) {
                    // Do not leave this result installed if Android cannot launch the picker.
                    if (pendingFilePicker === pending) pendingFilePicker = null
                    result.error("PICKER", e.message ?: NativeI18n.text("無法開啟附件選擇器"), null)
                }
                return@setMethodCallHandler
            }
            runtime.scope.launch {
                try {
                    val value: Any? = when (call.method) {
                        "boot" -> runtime.boot().also {
                            documentScripts.onPairingStampChanged(it["pairingStamp"] as? String)
                            htmlMedia.closeStalePairingStamp(it["pairingStamp"] as? String)
                        } + mapOf("onboardingComplete" to activity.permissionAccess.complete, "pairLink" to activity.intent?.dataString,
                            "route" to activity.intent?.getStringExtra("gatewayRoute"), "targetSession" to activity.intent?.getStringExtra("gatewaySession"),
                            "eventId" to activity.intent?.getStringExtra("gatewayEventId"), "occurrenceStart" to activity.intent?.getStringExtra("gatewayOccurrenceStart"),
                            "eventDate" to activity.intent?.getStringExtra("gatewayEventDate"),
                            "eventStartAt" to activity.intent?.takeIf { it.hasExtra("gatewayEventStartAt") }?.getLongExtra("gatewayEventStartAt", 0),
                            "interactionId" to activity.intent?.getStringExtra("interactionId"), "interactionEpoch" to activity.intent?.getStringExtra("interactionEpoch"),
                            "interactionPairingStamp" to activity.intent?.getStringExtra("questionPairingStamp"),
                            "questionPairingStamp" to activity.intent?.getStringExtra("questionPairingStamp"),
                            "answerChoice" to activity.intent?.getStringExtra("answerChoice"), "confirmQuestion" to activity.intent?.getBooleanExtra("confirmQuestion",false))
                        "openContext" -> accountContextMutationLock.withLock {
                            runtime.openContext(str("contextId"), str("pairingStamp")).also {
                                documentScripts.onPairingStampChanged(it["pairingStamp"] as? String)
                                htmlMedia.closeStalePairingStamp(it["pairingStamp"] as? String)
                            }
                        }
                        "closeContext" -> {
                            val closingContext = str("contextId")
                            clearExternalDropContext(closingContext)
                            projectFileSelections.closeContext(closingContext)
                            documentScripts.closeContext(closingContext)
                            accountContextMutationLock.withLock {
                                htmlMedia.closeContext(closingContext)
                                runtime.closeContext(closingContext)
                            }
                            null
                        }
                        "setExternalImageDropTarget" -> {
                            setExternalImageDropTarget(contextId, args)
                            null
                        }
                        "clearExternalImageDropTarget" -> {
                            clearExternalImageDropTarget(contextId, args)
                            null
                        }
                        "preferences" -> NotificationPreferences(activity).read()
                        "savePreferences" -> {
                            val preferences = NotificationPreferences(activity)
                            preferences.save(args)
                            if (args.containsKey("language")) GatewayNotifications.manager(activity)
                            preferences.read().also(runtime::notifyPreferencesChanged)
                        }
                        "calendarPreferences" -> {
                            val digest = java.security.MessageDigest.getInstance("SHA-256")
                                .digest(str("accountKey").toByteArray(Charsets.UTF_8))
                                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
                            val prefs = activity.getSharedPreferences("calendar_view_preferences", Context.MODE_PRIVATE)
                            mapOf(
                                "view" to prefs.getString("$digest:view", null),
                                "timezone" to prefs.getString("$digest:timezone", null),
                                "weekStart" to prefs.getString("$digest:weekStart", null),
                            )
                        }
                        "saveCalendarPreferences" -> {
                            val digest = java.security.MessageDigest.getInstance("SHA-256")
                                .digest(str("accountKey").toByteArray(Charsets.UTF_8))
                                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
                            val prefs = activity.getSharedPreferences("calendar_view_preferences", Context.MODE_PRIVATE)
                            val edit = prefs.edit()
                            for (key in listOf("view", "timezone", "weekStart")) {
                                (args[key] as? String)?.let { edit.putString("$digest:$key", it) }
                            }
                            edit.apply()
                            null
                        }
                        "appSettings" -> {
                            activity.startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(android.net.Uri.parse("package:${activity.packageName}"))); null
                        }
                        "notificationSettings" -> {
                            activity.startActivity(Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, activity.packageName)); null
                        }
                        "share" -> {
                            activity.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, str("text")), NativeI18n.text("分享內容"))); null
                        }
                        "permissions" -> activity.permissionAccess.status()
                        "requestOverlay" -> { activity.permissionAccess.overlay(); activity.permissionAccess.status() }
                        "completeOnboarding" -> { activity.permissionAccess.finish(); null }
                        "activity" -> PircJson.parseToJsonElement(activity.getSharedPreferences("recent_activity", Activity.MODE_PRIVATE).getString("items", "[]")!!).wire()
                        "pair" -> accountContextMutationLock.withLock {
                            firstSend.clear()
                            clearProjectFileSelections()
                            documentScripts.closeAll()
                            clearExternalDropTargets()
                            recordings.closeAll()
                            htmlMedia.closeAll()
                            runtime.pair(str("link"))
                        }
                        "unpair" -> accountContextMutationLock.withLock {
                            firstSend.clear()
                            clearProjectFileSelections()
                            documentScripts.closeAll()
                            clearExternalDropTargets()
                            recordings.closeAll()
                            htmlMedia.closeAll()
                            runtime.unpair()
                            null
                        }
                        "resolveDocumentUrl" -> NativeDocumentTransport(null).resolveUrl(str("reference"), str("baseUrl"))
                        "documentScriptCapabilities" -> documentScripts.capabilities()
                        "documentScriptOpen" -> accountContextMutationLock.withLock {
                            val boot = runtime.boot()
                            documentScripts.onPairingStampChanged(boot["pairingStamp"] as? String)
                            val opened = documentScripts.open(
                                str("owner"), str("documentUrl"), contextId, optionalString("blobCreatorUrl"), optionalString("storageSessionKey"),
                            )
                            try {
                                val url = str("documentUrl")
                                val cookieState = if (url.startsWith("http://") || url.startsWith("https://")) {
                                    runtime.documentCookieState(documentScripts.resourcePrincipal(opened, str("owner"), contextId), url)
                                } else null
                                val principal = documentScripts.resourcePrincipal(opened, str("owner"), contextId)
                                val storageState = if (principal.documentOrigin != "null") {
                                    runtime.documentStorageState(principal, url)
                                } else null
                                mapOf("id" to opened, "cookieState" to cookieState, "storageState" to storageState)
                            } catch (error: Exception) {
                                documentScripts.close(opened, str("owner"), contextId)
                                runtime.documentStorageCloseReader(str("owner"), contextId)
                                throw error
                            }
                        }
                        "documentScriptStorage" -> {
                            val principal = documentScripts.resourcePrincipal(requiredInt("id"), str("owner"), contextId)
                            val operations = args["operations"] as? List<*> ?: emptyList<Any>()
                            require(operations.size <= 256 && operations.all { it is Map<*, *> }) { "Invalid browser storage operations" }
                            val state = runtime.documentStorageState(principal,
                                optionalString("documentUrl") ?: principal.documentUrl,
                                operations.map { it as Map<*, *> },
                                (args["revision"] as? Number)?.toLong(),
                                (args["generation"] as? Number)?.toLong())
                            check(documentScripts.resourcePrincipal(requiredInt("id"), str("owner"), contextId) == principal) {
                                "The storage document closed while processing its state"
                            }
                            state
                        }
                        "documentStorageWindowOpen", "documentStorageWindowClose" -> {
                            runtime.documentStorageWindow(call.method == "documentStorageWindowOpen",
                                str("sessionKey"), optionalString("openerKey"), str("pairingStamp"))
                            null
                        }
                        "documentScriptCookies" -> {
                            val principal = documentScripts.resourcePrincipal(requiredInt("id"), str("owner"), contextId)
                            val writes = args["writes"] as? List<*> ?: emptyList<Any>()
                            require(writes.size <= 256 && writes.all { it is Map<*, *> }) { "Invalid cookie writes" }
                            runtime.documentCookieState(principal, optionalString("documentUrl") ?: principal.documentUrl,
                                writes.map { it as Map<*, *> })
                        }
                        "documentPrepareRequest" -> runtime.documentPrepareRequest(
                            str("url"), optionalString("baseUrl"), str("pairingStamp"),
                            optionalString("method") ?: "GET", optionalString("resourceType") ?: "document",
                            optionalString("initiatorUrl") ?: optionalString("originUrl") ?: optionalString("referrerUrl"),
                            optionalString("topLevelUrl") ?: optionalString("initiatorUrl") ?: optionalString("originUrl") ?: optionalString("referrerUrl"),
                        )
                        "documentScriptCanvasTextResources" -> documentScripts.prepareCanvasText(
                            requiredInt("id"), str("owner"), contextId,
                            (args["families"] as? List<*>)?.map { require(it is String); it }
                                ?: error("Canvas text font families are required"), str("sample"),
                        )
                        "documentScriptEvaluate" -> mapOf(
                            "value" to documentScripts.evaluate(
                                requiredInt("id"), str("owner"), str("source"), contextId,
                            ),
                        )
                        "documentStylesheet" -> {
                            val request = parseDocumentScriptResourceRequest(args["request"])
                            check(request.kind == NativeScriptResourceTransport.Kind.STYLESHEET) {
                                "Initial document resource must be a stylesheet"
                            }
                            documentScriptResourceWire(runtime.documentStylesheet(
                                documentUrl = str("documentUrl"),
                                blobCreatorUrl = optionalString("blobCreatorUrl"),
                                contextId = contextId,
                                expectedPairingStamp = str("pairingStamp"),
                                request = request,
                            ))
                        }
                        "documentScriptResource" -> {
                            val id = requiredInt("id")
                            val owner = str("owner")
                            val rawRequest = args["request"] as? Map<*, *>
                                ?: throw IllegalArgumentException("Document resource request is required")
                            val requestId = rawRequest["id"] as? String
                                ?: throw IllegalArgumentException("Document resource identifier is required")
                            val request = parseDocumentScriptResourceRequest(rawRequest)
                            check(requestId.substringBefore('-') == rawRequest["kind"]) {
                                "The document resource identifier kind does not match"
                            }
                            val lease = documentScripts.beginResource(id, owner, contextId, requestId)
                            try {
                                val response = runtime.documentScriptResource(lease.principal, request, lease.cancellation)
                                lease.cancellation.throwIfCancelled()
                                // A closed/replaced isolate must never receive a stale completion.
                                check(documentScripts.resourcePrincipal(id, owner, contextId) == lease.principal) {
                                    "The document script session closed while loading a resource"
                                }
                                if (request.kind in setOf(NativeScriptResourceTransport.Kind.CLASSIC_SCRIPT,
                                        NativeScriptResourceTransport.Kind.MODULE_SCRIPT)) {
                                    lease.principal.scriptSources?.recordScriptUrl(response.url)
                                }
                                documentScriptResourceWire(response)
                            } finally {
                                documentScripts.finishResource(lease)
                            }
                        }
                        "documentScriptResourceCancel" -> {
                            documentScripts.cancelResource(
                                requiredInt("id"), str("owner"), contextId, str("requestId"),
                            )
                            null
                        }
                        "documentScriptClose" -> {
                            documentScripts.close(requiredInt("id"), str("owner"), contextId)
                            runtime.documentStorageCloseReader(str("owner"), contextId)
                            null
                        }
                        "document" -> runtime.document(
                            str("url"),
                            str("method"),
                            optionalString("body"),
                            args["contentType"] as? String,
                            args["baseUrl"] as? String,
                            str("pairingStamp"),
                            when (args["resourceType"]) {
                                null, "document" -> NativeDocumentTransport.ResourceType.DOCUMENT
                                "stylesheet" -> NativeDocumentTransport.ResourceType.STYLESHEET
                                else -> throw IllegalArgumentException("Unsupported document resourceType")
                            },
                            when (args["cacheMode"]) {
                                null, "default" -> NativeDocumentTransport.CacheMode.DEFAULT
                                "reload" -> NativeDocumentTransport.CacheMode.RELOAD
                                "revalidate" -> NativeDocumentTransport.CacheMode.REVALIDATE
                                else -> throw IllegalArgumentException("Unsupported document cacheMode")
                            },
                            optionalString("ifNoneMatch"),
                            optionalString("ifModifiedSince"),
                            optionalBytes("bodyBytes"),
                            optionalString("referrerUrl"),
                            optionalString("referrerPolicy"),
                            optionalString("originUrl"),
                            optionalString("initiatorUrl"),
                            optionalString("topLevelUrl"),
                        )
                        "image" -> runtime.image(str("source"), optionalString("baseUrl"), optionalString("documentUrl"), optionalString("crossOrigin"))
                        "imageCapabilities" -> NativeRasterImages.capabilities()
                        "normalizeAvif" -> NativeRasterImages.normalize(optionalBytes("bytes") ?: throw IllegalArgumentException("Image bytes are required"))
                        "managementStatus" -> runtime.managementStatus()
                        "managementBegin" -> runtime.managementBegin(optionalStringList("capabilities") ?: throw IllegalArgumentException("capabilities is required"))
                        "managementCheck" -> runtime.managementCheck()
                        "managementCancel" -> runtime.managementCancel()
                        "managementOpen" -> {
                            val url = runtime.managementUrl()
                            activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            null
                        }
                        "firstSendSubmit" -> firstSend.submit(str("pairingStamp"), str("ownerUser"), str("operationId"), (args["expectedRevision"] as? Number)?.toLong(), runtime.local.clientId)
                        "firstSendRecoverRetry" -> firstSend.recoverRetry(str("pairingStamp"), str("ownerUser"), str("operationId"), runtime.local.clientId)
                        "firstSendRetry" -> firstSend.retry(str("pairingStamp"), str("ownerUser"), str("operationId"), runtime.local.clientId)
                        "firstSendCheck" -> firstSend.check(str("pairingStamp"), str("ownerUser"), str("operationId"))
                        "firstSendCancel" -> firstSend.cancel(str("pairingStamp"), str("ownerUser"), str("operationId"), args["deleteAccepted"] == true)
                        "firstSendStop" -> firstSend.stop(str("pairingStamp"), str("ownerUser"), str("operationId"), runtime.local.clientId)
                        "firstSendTakeControl" -> firstSend.takeControl(str("pairingStamp"), str("ownerUser"), str("operationId"), runtime.local.clientId)
                        "firstSendRelease" -> firstSend.release(str("pairingStamp"), str("ownerUser"), str("operationId"))
                        "firstSendAdopt" -> firstSend.adopt(str("pairingStamp"), str("ownerUser"), str("sessionId"))
                        "firstSendCapabilities" -> firstSend.capabilities(str("pairingStamp"))
                        "firstSendDrafts" -> firstSend.drafts(str("pairingStamp"), str("ownerUser"), args)
                        "request" -> {
                            val expectedStamp = optionalString("pairingStamp")
                            if (expectedStamp == null) runtime.request(str("method"), str("path"), args["body"])
                            else runtime.requestWithApi(capturePairedApi(expectedStamp, contextId), str("method"), str("path"), args["body"])
                        }
                        "watch" -> { runtime.watch(str("sessionId"), contextId, optionalString("watchTag")); runtime.local.draft(str("sessionId")) }
                        "setWatchVisibility" -> runtime.setWatchVisibility(
                            contextId,
                            args["visible"] as? Boolean
                                ?: throw IllegalArgumentException("visible must be a boolean"),
                            requiredLong("visibilityRevision"),
                            optionalString("watchTag"),
                        )
                        "commandStatus" -> runtime.unknownCommand(str("sessionId"))
                        "stopDelegation" -> runtime.stopDelegation(str("delegationId"))
                        "answerRelayed" -> runtime.answerRelayed(str("sessionId"), str("interactionId"), str("pairingStamp"),
                            args["confirmed"] as? Boolean ?: throw IllegalArgumentException("confirmed must be a boolean"))
                        "acknowledgeCommand" -> { runtime.acknowledgeCommand(str("sessionId")); null }
                        "recordingOpen" -> recordings.open(str("sessionId"), str("path"))
                        "recordingControl" -> recordings.control((args["id"] as Number).toLong(), str("action"), (args["position"] as? Number)?.toLong(), (args["volume"] as? Number)?.toDouble(), (args["rate"] as? Number)?.toDouble())
                        "recordingClose" -> { recordings.close((args["id"] as Number).toLong()); null }
                        "recordingSave" -> recordings.save(str("sessionId"), str("path"))
                        "htmlMediaOpen" -> htmlMedia.open(
                            validateHtmlMediaOpenRequest(
                                source = optionalString("source"),
                                bytes = optionalBytes("bytes"),
                                mimeType = optionalString("mimeType"),
                                baseUrl = optionalString("baseUrl"),
                                pairingStamp = optionalString("pairingStamp"),
                                kind = optionalString("kind"),
                                muted = optionalBoolean("muted"),
                                loop = optionalBoolean("loop"),
                                documentUrl = optionalString("documentUrl"),
                            ),
                            contextId,
                        )
                        "htmlMediaControl" -> htmlMedia.control(
                            id = requiredLong("id"),
                            contextId = contextId,
                            action = str("action"),
                            position = (args["position"] as? Number)?.toLong(),
                            volume = (args["volume"] as? Number)?.toDouble(),
                            rate = (args["rate"] as? Number)?.toDouble(),
                            loop = optionalBoolean("loop"),
                        )
                        "htmlMediaClose" -> {
                            htmlMedia.close(requiredLong("id"), contextId)
                            null
                        }
                        "htmlMediaRead" -> htmlMedia.read(requiredLong("id"), contextId)
                        "clipboardImagesAvailable" -> {
                            val manager = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            manager.primaryClipDescription?.hasMimeType("image/*") == true
                        }
                        "readClipboard" -> {
                            val manager = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            val clip = manager.primaryClip
                            val text = if (clip?.description?.hasMimeType("text/plain") == true)
                                (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).text?.toString() }.joinToString("\n")
                            else ""
                            val uris = if (clip == null) emptyList() else
                                (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }
                            val files = withContext(Dispatchers.IO) {
                                uris.mapNotNull { uri ->
                                    try {
                                        val mime = activity.contentResolver.getType(uri)
                                        if (mime?.startsWith("image/") != true) null else attachmentWire(readAttachment(uri))
                                    } catch (e: Exception) {
                                        attachmentWire(AttachmentRead.Failure(uri.lastPathSegment ?: "image", "image/unknown", e.message ?: NativeI18n.text("無法讀取剪貼簿圖片")))
                                    }
                                }
                            }
                            mapOf("text" to text, "files" to files)
                        }
                        "releaseProjectFiles" -> {
                            val tokens = optionalStringList("fileTokens") ?: emptyList()
                            projectFileSelections.release(tokens, contextId)
                            null
                        }
                        "uploadProjectFile" -> {
                            val workspaceId = str("workspaceId")
                            val name = str("name")
                            val stamp = str("pairingStamp")
                            val limit = projectFileLimit(args["maxBytes"])
                            val api = projectFileApi(stamp, contextId)
                            val token = optionalString("fileToken")
                            val bytes = optionalBytes("bytes")
                            require((token == null) != (bytes == null)) { "Specify either fileToken or bytes" }
                            val body = if (token != null) {
                                val selection = projectFileSelections.consume(token, workspaceId, stamp, contextId)
                                require(selection.name == name) { "Selected file name changed" }
                                ProjectFileUploadBody(limit) { activity.contentResolver.openInputStream(Uri.parse(selection.uri)) }
                            } else {
                                requireNotNull(bytes)
                                if (bytes.isEmpty() || bytes.size > limit) throw ApiException(413, "payload_too_large", NativeI18n.text("File is empty or exceeds the project file size limit."))
                                ProjectFileUploadBody(limit) { bytes.inputStream() }
                            }
                            api.uploadProjectFile(workspaceId, name, body).wire()
                        }
                        "uploadAttachment" -> {
                            val sessionId = str("sessionId")
                            val name = str("name")
                            val mimeType = str("mimeType")
                            val bytes = args["bytes"] as? ByteArray
                                ?: throw IllegalArgumentException("bytes 必須是 Uint8List")
                            require(bytes.size <= MAX_ATTACHMENT_BYTES) { NativeI18n.text("附件上限 8 MiB") }
                            withContext(Dispatchers.IO) {
                                val uploaded = runtime.api().upload(sessionId, bytes, mimeType, name)
                                mapOf(
                                    "id" to uploaded.id,
                                    "name" to name,
                                    "kind" to uploaded.kind,
                                    "mimeType" to mimeType,
                                    "size" to bytes.size,
                                )
                            }
                        }
                        "fileLink" -> parseFileLink(str("href"), args["base"] as? String ?: "")?.let { mapOf("path" to it.path, "line" to it.line) }
                        "timeZoneInfo" -> mapOf("default" to java.time.ZoneId.systemDefault().id, "zones" to java.time.ZoneId.getAvailableZoneIds().sorted())
                        "wallInput" -> wallInput((args["at"] as Number).toLong(), str("timezone"))
                        "calendarDateStart" -> calendarDateStart(str("date"), str("timezone"))
                        "calendarWallInstant" -> calendarWallInstant(str("value"), str("timezone"))
                        "unwatch" -> { runtime.unwatch(contextId, optionalString("watchTag")); null }
                        "refresh" -> runtime.snapshot(str("sessionId")).wire()
                        "draft" -> { runtime.local.saveDraft(str("sessionId"), str("text")); null }
                        "control" -> runtime.lease(str("sessionId"), args["acquire"] == true, args["force"] == true)
                        "command" -> runtime.command(str("sessionId"), args["payload"] as Map<*, *>, str("commandId"), args["expectedBinding"]?.json())
                        "answer" -> runtime.answer(str("sessionId"), str("interactionId"), str("epoch"), str("pairingStamp"), args["answer"] as Map<*, *>)
                        "reconcileAnswer" -> runtime.reconcileAnswer(str("sessionId"), str("interactionId"), str("epoch"), str("pairingStamp"))
                        "socketOpen" -> { runtime.openSocket(str("tag"), str("path"), contextId); null }
                        "socketSend" -> { runtime.sendSocket(str("tag"), args["data"] as Map<*, *>, contextId); null }
                        "socketClose" -> { runtime.closeSocket(str("tag"), contextId); null }
                        "pushStatus" -> {
                            PushRegistration.load(activity)
                            mapOf("distributors" to PushRegistration.distributors(activity),
                                "subscriptionId" to PushRegistration.subscriptionId(activity),
                                "code" to when(PushRegistration.status.value) {
                                    PushStatus.Off -> "off"
                                    PushStatus.Connecting -> "connecting"
                                    is PushStatus.On -> "on"
                                    is PushStatus.Failed -> "failed"
                                }, "state" to when(val state = PushRegistration.status.value) {
                                PushStatus.Off -> NativeI18n.text("尚未啟用")
                                PushStatus.Connecting -> NativeI18n.text("註冊中")
                                is PushStatus.On -> NativeI18n.text("已啟用：{0}", state.distributor)
                                is PushStatus.Failed -> state.reason
                            })
                        }
                        "pushEnable" -> {
                            val job = currentCoroutineContext().job
                            pushEnableJobs.add(job)
                            try {
                                pushEnableCoordinator.run(
                                    hasDistributor = {
                                        PushRegistration.distributors(activity).isNotEmpty()
                                    },
                                    captureSnapshot = { capturePushEnableSnapshot(contextId) },
                                    selectDistributor = { selectPushDistributor() },
                                    validateSnapshot = { snapshot ->
                                        validatePushEnableSnapshot(snapshot as PushEnableSnapshot)
                                    },
                                    enable = { snapshot ->
                                        val lease = snapshot as PushEnableSnapshot
                                        accountContextMutationLock.withLock {
                                            validatePushEnableSnapshot(lease)
                                            val api = runtime.api()
                                            validatePushEnableSnapshot(lease)
                                            PushRegistration.enable(activity, api)
                                        }
                                    },
                                )
                            } finally {
                                pushEnableJobs.remove(job)
                            }
                            null
                        }
                        "pushDisable" -> accountContextMutationLock.withLock {
                            PushRegistration.disable(activity, runtime.api()); null
                        }
                        "overlay" -> {
                            val id = args["sessionId"] as? String
                            val schedule = args["scheduleId"] as? String
                            require(id != null || schedule != null)
                            if (!android.provider.Settings.canDrawOverlays(activity)) {
                                GatewayNotifications.show(activity, NativeI18n.text("pirc · 待你處理"), NativeI18n.text("開啟 App 確認最新狀態"), id, schedule?.let { "schedule:$it" }, if(schedule!=null) "missed" else "q")
                                NativeI18n.text("浮窗權限尚未開啟，已嘗試改用通知；也可直接在對話內回答")
                            } else {
                                activity.startForegroundService(Intent(activity, GatewayOverlayService::class.java)
                                    .putExtra("sessionId", id).putExtra("interactionId", args["interactionId"] as? String)
                                    .putExtra("interactionEpoch", args["interactionEpoch"]?.toString())
                                    .putExtra("questionPairingStamp", args["interactionPairingStamp"] as? String ?: args["questionPairingStamp"] as? String ?: args["pairingStamp"] as? String)
                                    .putExtra("scheduleId",schedule))
                                activity.moveTaskToBack(true)
                                null
                            }
                        }
                        "openPairLink" -> {
                            val uri = Uri.parse(str("url"))
                            require(uri.scheme == "pirc" && uri.host == "pair")
                            val gateway = Uri.parse(requireNotNull(uri.getQueryParameter("url")))
                            require(gateway.scheme in listOf("https", "http") && !gateway.host.isNullOrBlank())
                            require(!uri.getQueryParameter("token").isNullOrBlank())
                            activity.startActivity(Intent(Intent.ACTION_VIEW, uri).setPackage(activity.packageName)); null
                        }
                        "external" -> {
                            val uri = Uri.parse(str("url"))
                            require(uri.scheme in listOf("https", "http"))
                            activity.startActivity(Intent(Intent.ACTION_VIEW, uri)); null
                        }
                        else -> { result.notImplemented(); return@launch }
                    }
                    result.success(value)
                } catch (e: CancellationException) { result.error("CANCELLED", NativeI18n.text("操作已取消，請檢查狀態"), null) }
                catch (e: DocumentScriptException) { result.error(e.code, e.message, null) }
                catch (e: ProjectFileReadException) { result.error("PROJECT_FILE_READ", e.message, null) }
                catch (e: PushEnableFailure) { result.error(e.code, e.message, null) }
                catch (e: ApiException) { result.error("HTTP_${e.status}", e.message, mapOf("status" to e.status, "code" to e.code)) }
                catch (e: Exception) {
                    android.util.Log.e("PircBridge", "${call.method}/${args["method"] ?: ""}: ${e.javaClass.name}/${e.cause?.javaClass?.name} at ${e.stackTrace.take(8).joinToString()}")
                    result.error(if (e is IllegalArgumentException) "INVALID" else "NETWORK", e.message ?: NativeI18n.text("連線失敗"), null)
                }
            }
        }
    }

    private data class PushEnableSnapshot(
        val pairingStamp: String,
        val contextId: String?,
        val contextGeneration: Long,
    )

    private suspend fun capturePushEnableSnapshot(contextId: String?): PushEnableSnapshot {
        val boot = runtime.boot()
        val pairingStamp = boot["pairingStamp"] as? String
        if (pairingStamp.isNullOrBlank()) {
            throw ApiException(401, "unpaired", NativeI18n.text("請先配對此裝置"))
        }
        runtime.validateContext(contextId)
        return PushEnableSnapshot(
            pairingStamp = pairingStamp,
            contextId = contextId,
            contextGeneration = contextGeneration.get(),
        )
    }

    private suspend fun validatePushEnableSnapshot(snapshot: PushEnableSnapshot) {
        if (contextGeneration.get() != snapshot.contextGeneration) {
            throw ApiException(409, "context_expired", NativeI18n.text("App context changed; reopen notification settings and try again."))
        }
        val currentStamp = runtime.boot()["pairingStamp"] as? String
        requirePairingStamp(snapshot.pairingStamp, currentStamp)
        runtime.validateContext(snapshot.contextId)
        if (contextGeneration.get() != snapshot.contextGeneration) {
            throw ApiException(409, "context_expired", NativeI18n.text("App context changed; reopen notification settings and try again."))
        }
    }

    private suspend fun selectPushDistributor(): Boolean =
        suspendCancellableCoroutine { continuation ->
            distributorPickerContinuation = continuation
            continuation.invokeOnCancellation {
                if (distributorPickerContinuation === continuation) {
                    distributorPickerContinuation = null
                }
            }
            if (!continuation.isActive) {
                if (distributorPickerContinuation === continuation) {
                    distributorPickerContinuation = null
                }
                return@suspendCancellableCoroutine
            }
            try {
                if (activity.isFinishing || activity.isDestroyed) {
                    throw PushEnableFailure("PUSH_PICKER", NativeI18n.text("Cannot open the distributor picker right now."))
                }
                UnifiedPush.tryUseCurrentOrDefaultDistributor(activity) { chosen ->
                    if (distributorPickerContinuation === continuation) {
                        distributorPickerContinuation = null
                    }
                    if (continuation.isActive) continuation.resume(chosen)
                }
            } catch (error: Exception) {
                if (distributorPickerContinuation === continuation) {
                    distributorPickerContinuation = null
                }
                if (continuation.isActive) {
                    if (error is PushEnableFailure) continuation.resumeWithException(error)
                    else continuation.resumeWithException(
                        PushEnableFailure("PUSH_PICKER", NativeI18n.text("Could not open the distributor picker right now.")),
                    )
                }
            }
        }

    private fun cancelPendingDistributorPicker() {
        distributorPickerContinuation?.cancel()
        distributorPickerContinuation = null
    }

    fun onFileResult(resultCode: Int, intent: Intent?) {
        val pending = pendingFilePicker ?: return
        pendingFilePicker = null
        val result = pending.result
        if (resultCode != Activity.RESULT_OK) { result.success(null); return }
        if (pending.mode == FilePickerMode.PROJECT_FILES) {
            completeProjectFilePicker(pending, selectedUris(intent))
            return
        }
        if (pending.mode == FilePickerMode.LEGACY_UPLOAD) {
            val uri = intent?.data
            if (uri == null) { result.success(null); return }
            val id = pending.sessionId ?: run {
                result.error("UPLOAD", NativeI18n.text("缺少工作階段"), null)
                return
            }
            runtime.scope.launch {
                try {
                    val upload = withContext(Dispatchers.IO) {
                        val contents = when (val read = readAttachment(uri)) {
                            is AttachmentRead.Success -> read.contents
                            is AttachmentRead.Failure -> throw IllegalArgumentException(read.error)
                        }
                        val uploaded = runtime.api().upload(id, contents.bytes, contents.mimeType, contents.name)
                        mapOf("id" to uploaded.id, "name" to contents.name, "kind" to uploaded.kind)
                    }
                    result.success(upload)
                } catch (e: Exception) { result.error("UPLOAD", e.message, null) }
            }
            return
        }

        val uris = selectedUris(intent)
        if (uris.isEmpty()) { result.success(null); return }
        runtime.scope.launch {
            try {
                val attachments = withContext(Dispatchers.IO) {
                    uris.map { uri ->
                        when (val read = readAttachment(uri)) {
                            is AttachmentRead.Success -> mapOf(
                                "name" to read.contents.name,
                                "mimeType" to read.contents.mimeType,
                                "bytes" to read.contents.bytes,
                            )
                            is AttachmentRead.Failure -> mapOf(
                                "name" to read.name,
                                "mimeType" to read.mimeType,
                                "error" to read.error,
                            )
                        }
                    }
                }
                result.success(attachments)
            } catch (e: Exception) { result.error("PICKER_READ", e.message, null) }
        }
    }

    fun onDocumentSaveResult(resultCode: Int, intent: Intent?) {
        documentSavePicker.onActivityResult(resultCode, intent)
    }

    private fun attachmentWire(read: AttachmentRead): Map<String, Any> = when (read) {
        is AttachmentRead.Success -> mapOf("name" to read.contents.name, "mimeType" to read.contents.mimeType, "bytes" to read.contents.bytes)
        is AttachmentRead.Failure -> mapOf("name" to read.name, "mimeType" to read.mimeType, "error" to read.error)
    }

    private fun setExternalImageDropTarget(contextId: String?, args: Map<*, *>) {
        fun requiredString(key: String, maxLength: Int = 128): String {
            val value = args[key] as? String ?: throw IllegalArgumentException("$key must be a string")
            require(value.isNotBlank() && value.length <= maxLength) { "Invalid $key" }
            return value
        }
        fun requiredNumber(values: Map<*, *>, key: String): Double {
            val value = values[key] as? Number ?: throw IllegalArgumentException("$key must be a number")
            val result = value.toDouble()
            require(result.isFinite()) { "Invalid $key" }
            return result
        }

        val view = activity.findViewById<FlutterView>(FlutterActivity.FLUTTER_VIEW_ID)
            ?: throw IllegalStateException("Flutter view is not ready")
        val rect = args["rect"] as? Map<*, *> ?: throw IllegalArgumentException("rect must be an object")
        val bounds = ExternalDropBounds.fromLogicalRect(
            left = requiredNumber(rect, "left"),
            top = requiredNumber(rect, "top"),
            right = requiredNumber(rect, "right"),
            bottom = requiredNumber(rect, "bottom"),
            devicePixelRatio = requiredNumber(args, "devicePixelRatio"),
            viewWidth = view.width,
            viewHeight = view.height,
        )
        val target = ExternalImageDropTarget(
            contextId = contextId ?: ContextRegistry.PRIMARY_CONTEXT_ID,
            targetId = requiredString("targetId"),
            scopeToken = requiredString("scopeToken"),
            sessionId = requiredString("sessionId"),
            bounds = bounds,
            lease = runtime.externalDropLease(contextId),
        )
        attachExternalDropListener(view)
        val previous = externalDropTargets.active(runtime::externalDropLeaseIsCurrent)
        externalDropTargets.register(target)
        if (previous != null && !externalDropTargets.isCurrent(previous)) {
            cancelExternalDropReads(previous.contextId, previous.targetId, previous.scopeToken)
        }
    }

    private fun clearExternalImageDropTarget(contextId: String?, args: Map<*, *>) {
        val targetId = args["targetId"] as? String ?: return
        val scopeToken = args["scopeToken"] as? String ?: return
        val owner = contextId ?: ContextRegistry.PRIMARY_CONTEXT_ID
        if (externalDropTargets.clear(owner, targetId, scopeToken)) {
            cancelExternalDropReads(owner, targetId, scopeToken)
        }
    }

    private fun clearExternalDropContext(contextId: String) {
        if (externalDropTargets.clearContext(contextId)) cancelExternalDropReads(contextId)
    }

    private fun clearExternalDropTargets() {
        externalDropTargets.clearAll()
        cancelExternalDropReads()
    }

    private fun cancelExternalDropReads(
        contextId: String? = null,
        targetId: String? = null,
        scopeToken: String? = null,
    ) {
        externalDropJobs.entries.toList().forEach { (job, target) ->
            val matches = (contextId == null || target.contextId == contextId) &&
                (targetId == null || target.targetId == targetId) &&
                (scopeToken == null || target.scopeToken == scopeToken)
            if (matches && externalDropJobs.remove(job, target)) {
                job.cancel(CancellationException("External drop target changed"))
            }
        }
    }

    private fun attachExternalDropListener(view: FlutterView) {
        if (externalDropView === view) return
        externalDropView?.setOnDragListener(null)
        view.setOnDragListener { _, event -> handleExternalImageDrag(event) }
        externalDropView = view
    }

    private fun handleExternalImageDrag(event: DragEvent): Boolean {
        val leaseIsCurrent: (ContextRegistry.Lease) -> Boolean = runtime::externalDropLeaseIsCurrent
        return when (event.action) {
            DragEvent.ACTION_DRAG_STARTED -> {
                val description = event.clipDescription
                val mimeTypes = description?.let { clip ->
                    (0 until clip.mimeTypeCount).map(clip::getMimeType)
                }
                acceptsImageDropStart(mimeTypes) &&
                    externalDropTargets.active(leaseIsCurrent) != null
            }
            DragEvent.ACTION_DRAG_ENTERED,
            DragEvent.ACTION_DRAG_LOCATION,
            DragEvent.ACTION_DRAG_EXITED,
            DragEvent.ACTION_DRAG_ENDED -> externalDropTargets.active(leaseIsCurrent) != null
            DragEvent.ACTION_DROP -> {
                val target = externalDropTargets.forDrop(event.x, event.y, leaseIsCurrent)
                    ?: return false
                val clip = event.clipData ?: return false
                val uris = (0 until clip.itemCount).mapNotNull { index -> clip.getItemAt(index).uri }
                if (uris.isEmpty()) return false
                val permissions = runCatching { activity.requestDragAndDropPermissions(event) }.getOrNull()
                startExternalImageDropRead(target, uris, permissions)
                true
            }
            else -> false
        }
    }

    private fun startExternalImageDropRead(
        target: ExternalImageDropTarget,
        uris: List<Uri>,
        permissions: android.view.DragAndDropPermissions?,
    ) {
        val dropId = java.util.UUID.randomUUID().toString()
        lateinit var job: Job
        job = runtime.scope.launch(start = CoroutineStart.LAZY) {
            try {
                val files = withContext(Dispatchers.IO) {
                    val candidates = uris.map { uri ->
                        ExternalDropCandidate(
                            value = uri,
                            mimeType = runCatching { activity.contentResolver.getType(uri) }.getOrNull(),
                        )
                    }
                    imageDropCandidates(candidates).map { candidate ->
                        imageAttachmentWire(readAttachment(candidate.value), candidate.mimeType!!)
                    }
                }
                if (files.isNotEmpty() && externalDropTargets.isCurrent(target) &&
                    runtime.externalDropLeaseIsCurrent(target.lease)
                ) {
                    runtime.emitExternalImageDrop(target, dropId, files)
                }
            } finally {
                runCatching { permissions?.release() }
                externalDropJobs.remove(job)
            }
        }
        externalDropJobs[job] = target
        job.start()
    }

    private fun imageAttachmentWire(read: AttachmentRead, candidateMimeType: String): Map<String, Any> =
        when (read) {
            is AttachmentRead.Success -> mapOf(
                "name" to read.contents.name,
                "mimeType" to if (read.contents.mimeType.startsWith("image/", ignoreCase = true)) {
                    read.contents.mimeType
                } else candidateMimeType,
                "bytes" to read.contents.bytes,
            )
            is AttachmentRead.Failure -> mapOf(
                "name" to read.name,
                "mimeType" to candidateMimeType,
                "error" to read.error,
            )
        }

    private fun selectedUris(intent: Intent?): List<Uri> {
        if (intent == null) return emptyList()
        val uris = ArrayList<Uri>()
        val seen = HashSet<Uri>()
        val clip = intent.clipData
        if (clip != null) {
            for (index in 0 until clip.itemCount) {
                val uri = clip.getItemAt(index).uri
                if (uri != null && seen.add(uri)) uris.add(uri)
            }
        }
        intent.data?.let { uri -> if (seen.add(uri)) uris.add(uri) }
        return uris
    }

    private fun projectFileLimit(value: Any?): Long {
        if (value == null) return MAX_PROJECT_FILE_BYTES
        val number = value as? Number ?: throw IllegalArgumentException("maxBytes must be an integer")
        val limit = number.toLong()
        require(number.toDouble() == limit.toDouble() && limit >= 0) { "Invalid project file size limit" }
        if (limit == 0L) return MAX_PROJECT_FILE_BYTES
        require(limit <= MAX_PROJECT_FILE_BYTES) { "Invalid project file size limit" }
        return limit
    }

    private suspend fun projectFileApi(stamp: String, contextId: String?): PircApi = capturePairedApi(stamp, contextId).also {
        projectFileSelections.bind(stamp)
    }

    private suspend fun capturePairedApi(stamp: String, contextId: String?): PircApi = accountContextMutationLock.withLock {
        runtime.validateContext(contextId)
        val current = runtime.boot()["pairingStamp"] as? String
        requirePairingStamp(stamp, current)
        runtime.api()
    }

    private fun clearProjectFileSelections() {
        projectFileSelections.clear()
        val pending = pendingFilePicker?.takeIf { it.mode == FilePickerMode.PROJECT_FILES } ?: return
        pendingFilePicker = null
        pending.result.error("HTTP_409", NativeI18n.text("The project or account changed. Choose the files again."), mapOf("status" to 409, "code" to "account_changed"))
    }

    private fun startProjectFilePicker(args: Map<*, *>, result: MethodChannel.Result, contextId: String?) {
        if (pendingFilePicker != null || documentSavePicker.isPending) {
            result.error("BUSY", "A file picker is already open.", null)
            return
        }
        val pending = try {
            val workspaceId = args["workspaceId"] as? String ?: throw IllegalArgumentException("workspaceId is required")
            val stamp = args["pairingStamp"] as? String ?: throw IllegalArgumentException("pairingStamp is required")
            require(workspaceId.isNotBlank() && stamp.isNotBlank()) { "Project and pairing are required" }
            projectFileLimit(args["maxBytes"])
            PendingFilePicker(result, FilePickerMode.PROJECT_FILES, workspaceId = workspaceId,
                pairingStamp = stamp, contextId = contextId, contextGeneration = contextGeneration.get())
        } catch (e: Exception) {
            result.error("INVALID", e.message, null)
            return
        }
        pendingFilePicker = pending
        runtime.scope.launch {
            try {
                projectFileApi(requireNotNull(pending.pairingStamp), contextId)
                if (pendingFilePicker !== pending) return@launch
                val picker = Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE)
                    .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, args["multiple"] != false)
                activity.startActivityForResult(picker, FILE_PICKER_REQUEST_CODE)
            } catch (e: Exception) {
                if (pendingFilePicker !== pending) return@launch
                pendingFilePicker = null
                if (e is ApiException) result.error("HTTP_${e.status}", e.message, mapOf("status" to e.status, "code" to e.code))
                else result.error("PICKER", e.message ?: NativeI18n.text("Unable to open the file picker."), null)
            }
        }
    }

    private fun completeProjectFilePicker(pending: PendingFilePicker, uris: List<Uri>) {
        runtime.scope.launch {
            try {
                val stamp = requireNotNull(pending.pairingStamp)
                val workspaceId = requireNotNull(pending.workspaceId)
                val selected = withContext(Dispatchers.IO) {
                    uris.map { uri ->
                        try {
                            var name = uri.lastPathSegment ?: "file"
                            var size: Long? = null
                            activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                                if (cursor.moveToFirst()) {
                                    val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                                    if (nameColumn >= 0 && !cursor.isNull(nameColumn)) name = cursor.getString(nameColumn).takeUnless { it.isBlank() } ?: name
                                    val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                                    if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) size = cursor.getLong(sizeColumn).takeIf { it >= 0 }
                                }
                            }
                            ProjectFileSelections.Selection(uri.toString(), name, size, workspaceId, stamp, pending.contextId) to null
                        } catch (e: Exception) {
                            null to mapOf("name" to (uri.lastPathSegment ?: "file"), "error" to (e.message ?: "Unable to read the selected file."))
                        }
                    }
                }
                projectFileApi(stamp, pending.contextId)
                if (pending.contextGeneration != contextGeneration.get()) throw ApiException(409, "context_expired", NativeI18n.text("App context changed. Choose the files again."))
                pending.result.success(selected.map { (selection, error) ->
                    if (selection == null) error else mapOf(
                        "name" to selection.name,
                        "byteSize" to selection.byteSize,
                        "fileToken" to projectFileSelections.add(selection),
                    )
                })
            } catch (e: Exception) {
                if (e is ApiException) pending.result.error("HTTP_${e.status}", e.message, mapOf("status" to e.status, "code" to e.code))
                else pending.result.error("PICKER_READ", e.message ?: NativeI18n.text("Unable to read the selected files."), null)
            }
        }
    }

    private fun readAttachment(uri: Uri): AttachmentRead {
        var name = "attachment"
        var mimeType = "application/octet-stream"
        return try {
            val resolver = activity.contentResolver
            name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0)?.takeIf { it.isNotBlank() } else null
            } ?: name
            mimeType = resolver.getType(uri)?.takeIf { it.isNotBlank() } ?: mimeType
            val bytes = resolver.openInputStream(uri)?.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    require(output.size() + count <= MAX_ATTACHMENT_BYTES) { NativeI18n.text("附件上限 8 MiB") }
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            } ?: throw java.io.IOException(NativeI18n.text("無法讀取附件"))
            AttachmentRead.Success(AttachmentContents(name, mimeType, bytes))
        } catch (e: Exception) {
            AttachmentRead.Failure(name, mimeType, e.message ?: NativeI18n.text("無法讀取附件"))
        }
    }
    fun route(intent: Intent) {
        runtime.emit("route", mapOf("sessionId" to intent.getStringExtra("gatewaySession"), "page" to intent.getStringExtra("gatewayRoute"), "pairLink" to intent.dataString,
            "eventId" to intent.getStringExtra("gatewayEventId"), "occurrenceStart" to intent.getStringExtra("gatewayOccurrenceStart"),
            "eventDate" to intent.getStringExtra("gatewayEventDate"),
            "eventStartAt" to intent.takeIf { it.hasExtra("gatewayEventStartAt") }?.getLongExtra("gatewayEventStartAt", 0),
            "interactionId" to intent.getStringExtra("interactionId"), "interactionEpoch" to intent.getStringExtra("interactionEpoch"),
            "interactionPairingStamp" to intent.getStringExtra("questionPairingStamp"), "questionPairingStamp" to intent.getStringExtra("questionPairingStamp"),
            "answerChoice" to intent.getStringExtra("answerChoice"), "confirmQuestion" to intent.getBooleanExtra("confirmQuestion",false)), sessionId = null)
    }
}
