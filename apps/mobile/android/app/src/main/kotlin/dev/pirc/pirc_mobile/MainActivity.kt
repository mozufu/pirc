package dev.pirc.pirc_mobile

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var gateway: GatewayBridge? = null
    val permissionAccess by lazy { PermissionAccess(this) }
    private val handler = Handler(Looper.getMainLooper())
    private var permissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        gateway = GatewayBridge(this, flutterEngine)
        val store = FixtureStore(this)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.pirc.mobile/validation").also { bridge ->
            bridge.setMethodCallHandler { call, result ->
                fun complete(action: () -> Any?) {
                    try { result.success(action()) }
                    catch (e: FixtureFailure) { result.error(e.code, "Fixture transition failed", null) }
                    catch (e: Exception) { result.error("NATIVE_ERROR", e.message, null) }
                }
                when (call.method) {
                    "read" -> handler.postDelayed({ complete { store.snapshot() } }, 350)
                    "answer" -> handler.postDelayed({ complete {
                        val args = call.arguments as Map<*, *>
                        val snapshot = store.answer((args["revision"] as Number).toLong(), args["choice"] as String)
                        QuickReplyNotifications.cancelQuestion(this)
                        snapshot
                    } }, 350)
                    "configure" -> complete {
                        stopService(Intent(this, QuickReplyService::class.java))
                        QuickReplyNotifications.cancelQuestion(this)
                        store.configure(call.arguments as String); null
                    }
                    "saveDraft" -> complete { store.saveDraft(call.arguments as String); null }
                    "newVersion" -> complete { store.newVersion(); null }
                    "requestOverlay" -> complete {
                        startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
                        null
                    }
                    "requestNotifications" -> {
                        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            if (permissionResult != null) result.error("BUSY", "Permission request already active", null)
                            else { permissionResult = result; requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7) }
                        } else result.success("通知權限已開啟")
                    }
                    "notify" -> complete {
                        if (QuickReplyNotifications.showQuestion(this)) "測試通知已發出，可以切到其他 App 後點通知中的快速回應"
                        else "通知尚未允許，請先開啟通知權限；問題仍保留在對話內"
                    }
                    "showOverlay" -> complete {
                        if (!Settings.canDrawOverlays(this)) {
                            val notified = QuickReplyNotifications.showQuestion(this)
                            if (notified) "浮窗權限尚未開啟，已改用通知" else "請開啟浮窗或通知權限；問題仍保留在對話內"
                        } else {
                            // Start from this visible, user-initiated Activity before backgrounding.
                            startForegroundService(Intent(this, QuickReplyService::class.java).setAction(QuickReplyService.SHOW))
                            moveTaskToBack(true)
                            null
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        permissionAccess.onResult(requestCode)
        if (requestCode == 7) {
            permissionResult?.success(if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) "通知權限已開啟" else "通知未允許，仍可在 App 內處理")
            permissionResult = null
        }
    }

    override fun onResume() {
        super.onResume()
        stopService(Intent(this, QuickReplyService::class.java))
        stopService(Intent(this, GatewayOverlayService::class.java))
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        gateway?.route(intent)
        if (intent.getStringExtra("sessionId") == FixtureStore.SESSION) {
            stopService(Intent(this, QuickReplyService::class.java))
            channel?.invokeMethod("openConversation", FixtureStore.SESSION)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 81) gateway?.onFileResult(resultCode, data)
    }
}
