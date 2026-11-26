package org.mozufu.pirc.images

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.mozufu.pirc.PlatformFeature
import org.mozufu.pirc.answerOn
import org.mozufu.pirc.mainThreadExecutor

/**
 * `org.mozufu.pirc/images`, called by pirc_render's `NativeRasterImages`:
 * `imageCapabilities` → `{avif: bool}`; `normalizeAvif {bytes}` → PNG bytes.
 * Errors: `INVALID` (not a static AVIF image, or no AVIF support) or `IMAGES`.
 */
class ImagesChannel(
    private val normalize: (ByteArray) -> ByteArray = RasterImages::normalize,
    private val work: Executor = Executors.newSingleThreadExecutor(),
    private val reply: Executor = mainThreadExecutor(),
) : PlatformFeature {
    override val name = "images"

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "imageCapabilities" -> result.success(RasterImages.capabilities())
            "normalizeAvif" -> {
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null) {
                    result.error("INVALID", "bytes is required", null)
                    return
                }
                result.answerOn(work, reply, "IMAGES") { normalize(bytes) }
            }
            else -> result.notImplemented()
        }
    }

    override fun detach() {
        (work as? ExecutorService)?.shutdown()
    }
}
