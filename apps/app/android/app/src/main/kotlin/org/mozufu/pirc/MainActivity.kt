package org.mozufu.pirc

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var channels: PlatformChannels? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channels?.detach()
        channels = PlatformChannels(PlatformChannels.features(this)).also {
            it.attach(flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channels?.detach()
        channels = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
