package dev.pirc.pirc_mobile

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import dev.pirc.android.core.*
import dev.pirc.android.push.PushRegistration
import dev.pirc.android.push.PushStatus
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.common.MlKitException

class GatewayBridge(private val activity: MainActivity, engine: FlutterEngine) {
    private val runtime = GatewayRuntime.get(activity)
    private var fileResult: MethodChannel.Result? = null
    private var fileSession: String? = null
    private var scanning = false
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "dev.pirc.mobile/gateway")

    init {
        EventChannel(engine.dartExecutor.binaryMessenger, "dev.pirc.mobile/events").setStreamHandler(object: EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) { runtime.listener = { sink.success(it) } }
            override fun onCancel(arguments: Any?) { runtime.listener = null; runtime.unwatch(); runtime.closeSockets() }
        })
        channel.setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
            fun str(key: String) = args[key] as String
            if (call.method == "requestNotifications") {
                try { activity.permissionAccess.notifications(result) }
                catch (e: Exception) { result.error("PERMISSION", e.message, null) }
                return@setMethodCallHandler
            }
            if (call.method == "scan") {
                if (scanning) { result.error("SCAN_BUSY", "掃描器已開啟", null); return@setMethodCallHandler }
                scanning = true
                fun failed(error: Exception) {
                    scanning = false
                    // Only class/stack locations: never log a scanned pairing link or token.
                    android.util.Log.e("PircScanner", "${error.javaClass.name} at ${error.stackTrace.take(8).joinToString()}")
                    val code = when ((error as? MlKitException)?.errorCode) {
                        200 -> "SCAN_DOWNLOADING"
                        207 -> "SCAN_UNSUPPORTED"
                        else -> "SCAN"
                    }
                    result.error(code, "無法開啟掃描器，請稍後重試或貼上配對連結。", null)
                }
                try {
                    val options = GmsBarcodeScannerOptions.Builder()
                        .setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
                    GmsBarcodeScanning.getClient(activity, options).startScan()
                        .addOnSuccessListener { scanning = false; result.success(it.rawValue) }
                        .addOnCanceledListener { scanning = false; result.success(null) }
                        .addOnFailureListener { failed(it) }
                } catch (e: Exception) { failed(e) }
                return@setMethodCallHandler
            }
            if (call.method == "pickUpload") {
                if (fileResult != null) { result.error("BUSY", "已有附件選擇器開啟", null); return@setMethodCallHandler }
                fileResult = result; fileSession = str("sessionId")
                activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE), 81)
                return@setMethodCallHandler
            }
            runtime.scope.launch {
                try {
                    val value: Any? = when (call.method) {
                        "boot" -> runtime.boot() + mapOf("onboardingComplete" to activity.permissionAccess.complete, "pairLink" to activity.intent?.dataString,
                            "route" to activity.intent?.getStringExtra("gatewayRoute"), "targetSession" to activity.intent?.getStringExtra("gatewaySession"), "interactionId" to activity.intent?.getStringExtra("interactionId"), "answerChoice" to activity.intent?.getStringExtra("answerChoice"), "confirmQuestion" to activity.intent?.getBooleanExtra("confirmQuestion",false))
                        "preferences" -> NotificationPreferences(activity).read()
                        "savePreferences" -> { NotificationPreferences(activity).save(args); NotificationPreferences(activity).read() }
                        "notificationSettings" -> {
                            activity.startActivity(Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, activity.packageName)); null
                        }
                        "share" -> {
                            activity.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, str("text")), "分享內容")); null
                        }
                        "permissions" -> activity.permissionAccess.status()
                        "requestOverlay" -> { activity.permissionAccess.overlay(); activity.permissionAccess.status() }
                        "completeOnboarding" -> { activity.permissionAccess.finish(); null }
                        "activity" -> PircJson.parseToJsonElement(activity.getSharedPreferences("recent_activity", Activity.MODE_PRIVATE).getString("items", "[]")!!).wire()
                        "pair" -> runtime.pair(str("link"))
                        "unpair" -> { runtime.unpair(); null }
                        "request" -> runtime.request(str("method"), str("path"), args["body"])
                        "watch" -> { runtime.watch(str("sessionId")); runtime.local.draft(str("sessionId")) }
                        "commandStatus" -> runtime.unknownCommand(str("sessionId"))
                        "acknowledgeCommand" -> { runtime.acknowledgeCommand(str("sessionId")); null }
                        "recording" -> {
                            val dir = java.io.File(activity.cacheDir, "recordings").apply { mkdirs() }
                            val dest = java.io.File(dir, "${java.util.UUID.randomUUID()}.webm")
                            runtime.api().downloadRecording(str("sessionId"), str("path"), dest)
                            val uri = androidx.core.content.FileProvider.getUriForFile(activity, "${activity.packageName}.files", dest)
                            activity.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "video/webm").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                            null
                        }
                        "fileLink" -> parseFileLink(str("href"), args["base"] as? String ?: "")?.let { mapOf("path" to it.path, "line" to it.line) }
                        "wallInput" -> wallInput((args["at"] as Number).toLong(), str("timezone"))
                        "unwatch" -> { runtime.unwatch(); null }
                        "refresh" -> runtime.snapshot(str("sessionId")).wire()
                        "draft" -> { runtime.local.saveDraft(str("sessionId"), str("text")); null }
                        "control" -> runtime.lease(str("sessionId"), args["acquire"] == true, args["force"] == true)
                        "command" -> runtime.command(str("sessionId"), args["payload"] as Map<*, *>, str("commandId"))
                        "answer" -> runtime.answer(str("sessionId"), str("interactionId"), str("epoch"), args["answer"] as Map<*, *>)
                        "socketOpen" -> { runtime.openSocket(str("tag"), str("path")); null }
                        "socketSend" -> { runtime.sendSocket(str("tag"), args["data"] as Map<*, *>); null }
                        "socketClose" -> { runtime.closeSocket(str("tag")); null }
                        "pushStatus" -> {
                            PushRegistration.load(activity)
                            mapOf("distributors" to PushRegistration.distributors(activity), "state" to when(val state = PushRegistration.status.value) {
                                PushStatus.Off -> "尚未啟用"
                                PushStatus.Connecting -> "註冊中"
                                is PushStatus.On -> "已啟用：${state.distributor}"
                                is PushStatus.Failed -> state.reason
                            })
                        }
                        "pushEnable" -> { PushRegistration.enable(activity, runtime.api()); null }
                        "pushDisable" -> { PushRegistration.disable(activity, runtime.api()); null }
                        "overlay" -> {
                            val id = args["sessionId"] as? String
                            val schedule = args["scheduleId"] as? String
                            require(id != null || schedule != null)
                            if (!android.provider.Settings.canDrawOverlays(activity)) {
                                GatewayNotifications.show(activity, "pirc · 待你處理", "開啟 App 確認最新狀態", id, schedule?.let { "schedule:$it" }, if(schedule!=null) "missed" else "q")
                                "浮窗權限尚未開啟，已嘗試改用通知；也可直接在對話內回答"
                            } else {
                                activity.startForegroundService(Intent(activity, GatewayOverlayService::class.java)
                                    .putExtra("sessionId", id).putExtra("interactionId", args["interactionId"] as? String).putExtra("scheduleId",schedule))
                                activity.moveTaskToBack(true)
                                null
                            }
                        }
                        "external" -> {
                            val uri = Uri.parse(str("url"))
                            require(uri.scheme in listOf("https", "http"))
                            activity.startActivity(Intent(Intent.ACTION_VIEW, uri)); null
                        }
                        else -> { result.notImplemented(); return@launch }
                    }
                    result.success(value)
                } catch (e: CancellationException) { result.error("CANCELLED", "操作已取消，請檢查狀態", null) }
                catch (e: ApiException) { result.error("HTTP_${e.status}", e.message, mapOf("status" to e.status, "code" to e.code)) }
                catch (e: Exception) {
                    android.util.Log.e("PircBridge", "${call.method}/${args["method"] ?: ""}: ${e.javaClass.name}/${e.cause?.javaClass?.name} at ${e.stackTrace.take(8).joinToString()}")
                    result.error(if (e is IllegalArgumentException) "INVALID" else "NETWORK", e.message ?: "連線失敗", null)
                }
            }
        }
    }
    fun onFileResult(resultCode: Int, intent: Intent?) {
        val result = fileResult ?: return
        val id = fileSession!!; fileResult = null; fileSession = null
        val uri = intent?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
        runtime.scope.launch {
            try {
                val upload = withContext(Dispatchers.IO) {
                    val resolver = activity.contentResolver
                    val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                        if (it.moveToFirst()) it.getString(0) else null
                    } ?: "attachment"
                    val mime = resolver.getType(uri) ?: "application/octet-stream"
                    val bytes = resolver.openInputStream(uri)!!.use { input ->
                        val output = java.io.ByteArrayOutputStream()
                        val buffer = ByteArray(8192)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            require(output.size() + count <= 8 * 1024 * 1024) { "附件上限 8 MiB" }
                            output.write(buffer, 0, count)
                        }
                        output.toByteArray()
                    }
                    require(bytes.size <= 8 * 1024 * 1024) { "附件上限 8 MiB" }
                    val uploaded = runtime.api().upload(id, bytes, mime, name)
                    mapOf("id" to uploaded.id, "name" to name, "kind" to uploaded.kind)
                }
                result.success(upload)
            } catch (e: Exception) { result.error("UPLOAD", e.message, null) }
        }
    }
    fun route(intent: Intent) {
        runtime.emit("route", mapOf("sessionId" to intent.getStringExtra("gatewaySession"), "page" to intent.getStringExtra("gatewayRoute"), "pairLink" to intent.dataString, "interactionId" to intent.getStringExtra("interactionId"), "answerChoice" to intent.getStringExtra("answerChoice"), "confirmQuestion" to intent.getBooleanExtra("confirmQuestion",false)))
    }
}
