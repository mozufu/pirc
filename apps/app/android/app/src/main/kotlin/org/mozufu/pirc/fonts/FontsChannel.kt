package org.mozufu.pirc.fonts

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.mozufu.pirc.PlatformFeature
import org.mozufu.pirc.answerOn
import org.mozufu.pirc.mainThreadExecutor

/**
 * `org.mozufu.pirc/fonts`: the system fonts for Canvas text in document scripts.
 * - `fontCapabilities` → `{canvasText: bool}` (Android 12 or later).
 * - `canvasTextFonts {families: [String], sample: String}` →
 *   `{resources: [{id, bytes, ttcIndex, originalTtcIndex, weight, italic, fakeBold,
 *   fakeItalic, axes: [{axis, value}], label}], matches: [{family, weight, italic,
 *   resourceIds}]}`, as [CanvasTextFonts.collect] returns it.
 * Errors: `UNSUPPORTED` (before Android 12), `INVALID` (bad arguments) or `FONTS`.
 */
class FontsChannel(
    private val collect: (List<String>, String) -> Map<String, Any?> = CanvasTextFonts::collect,
    private val supported: () -> Boolean = CanvasTextFonts::supported,
    private val work: Executor = Executors.newSingleThreadExecutor(),
    private val reply: Executor = mainThreadExecutor(),
) : PlatformFeature {
    override val name = "fonts"

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "fontCapabilities" -> result.success(mapOf("canvasText" to supported()))
            "canvasTextFonts" -> {
                val families = (call.argument<List<*>>("families") ?: emptyList<Any?>())
                    .map { it as? String }
                val sample = call.argument<String>("sample") ?: ""
                if (families.any { it == null }) {
                    result.error("INVALID", "families must be strings", null)
                    return
                }
                val names = families.filterNotNull()
                try {
                    CanvasTextFonts.checkRequest(names, sample)
                } catch (e: IllegalArgumentException) {
                    result.error("INVALID", e.message, null)
                    return
                }
                if (!supported()) {
                    result.error("UNSUPPORTED", "Canvas fonts need Android 12 or later", null)
                    return
                }
                result.answerOn(work, reply, "FONTS") { collect(names, sample) }
            }
            else -> result.notImplemented()
        }
    }

    override fun detach() {
        (work as? ExecutorService)?.shutdown()
    }
}
