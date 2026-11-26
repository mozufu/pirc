package org.mozufu.pirc

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var channels: PlatformChannels? = null

    /** Created again from saved state: the intent's link was already given. */
    private var restored = false

    override fun onCreate(savedInstanceState: Bundle?) {
        restored = savedInstanceState != null
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channels?.detach()
        channels = PlatformChannels(PlatformChannels.features(this, flutterEngine.renderer, restored)).also {
            it.attach(flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        channels?.newIntent(intent)
    }

    override fun onPause() {
        channels?.background()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        channels?.foreground()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channels?.detach()
        channels = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
