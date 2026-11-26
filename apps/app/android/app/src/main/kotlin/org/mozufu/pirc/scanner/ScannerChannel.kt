package org.mozufu.pirc.scanner

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.mlkit.common.MlKitException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicLong
import org.mozufu.pirc.PlatformFeature
import org.mozufu.pirc.mainThreadExecutor

/** What one scan answers to Dart. */
internal sealed class ScanAnswer {
    /** The QR code's text, or null when the user closed the scanner. */
    data class Text(val value: String?) : ScanAnswer()

    data class Failure(val code: String, val details: Map<String, Any>? = null) : ScanAnswer()
}

/** Maps a finished scan to the channel's answer. */
internal fun scanAnswer(outcome: BarcodeScanOutcome): ScanAnswer = when (outcome) {
    is BarcodeScanOutcome.Success -> ScanAnswer.Text(outcome.value?.takeIf { it.isNotEmpty() })
    BarcodeScanOutcome.Cancelled -> ScanAnswer.Text(null)
    is BarcodeScanOutcome.Failure -> {
        val error = outcome.error
        val code = when {
            error is BarcodeScanPreparationTimeoutException -> "SCAN_TIMEOUT"
            // The scanner module is still downloading.
            (error as? MlKitException)?.errorCode == 200 -> "SCAN_DOWNLOADING"
            // This device cannot run the scanner.
            (error as? MlKitException)?.errorCode == 207 -> "SCAN_UNSUPPORTED"
            else -> "SCAN"
        }
        val details = (error as? BarcodeScanModuleInstallException)?.let {
            mapOf<String, Any>("moduleInstallErrorCode" to it.errorCode)
        }
        ScanAnswer.Failure(code, details)
    }
}

/** Runs [action] after [delayMillis]; the returned function cancels it. */
internal fun interface ScanTimer {
    fun schedule(delayMillis: Long, action: () -> Unit): () -> Unit
}

/**
 * `org.mozufu.pirc/scanner`: `scan` → the text of one QR code, or null when the user
 * closed the scanner; `cancelPreparation` → whether a scan that had not shown its screen
 * yet was stopped. The scanner is the Google Play services code scanner (ML Kit), which
 * needs no camera permission; its module is installed first when it is missing.
 *
 * Errors: `SCAN_BUSY` (a scan is already open), `SCAN_TIMEOUT` (preparing took over 30
 * seconds), `SCAN_DOWNLOADING`, `SCAN_UNSUPPORTED` and `SCAN`. A scanned pairing link
 * holds a token, so the text is never logged or put in an error.
 */
class ScannerChannel internal constructor(
    private val newFlow: (onComplete: (BarcodeScanOutcome) -> Unit) -> BarcodeScanFlow,
    private val timer: ScanTimer = handlerTimer(),
    private val reply: Executor = mainThreadExecutor(),
) : PlatformFeature {
    override val name = "scanner"

    private val gate = BarcodeScanBusyGate()
    private val sequence = AtomicLong(0L)
    @Volatile private var active: BarcodeScanFlow? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "scan" -> scan(result)
            "cancelPreparation" -> result.success(active?.cancelPreparation() == true)
            else -> result.notImplemented()
        }
    }

    private fun scan(result: MethodChannel.Result) {
        val requestId = "scan-${sequence.incrementAndGet()}"
        if (!gate.tryEnter(requestId)) {
            result.error("SCAN_BUSY", "A scanner is already open", null)
            return
        }
        var flow: BarcodeScanFlow? = null
        var cancelTimeout: (() -> Unit)? = null
        var answered = false
        fun finish(outcome: BarcodeScanOutcome) {
            synchronized(this) {
                if (answered) return
                answered = true
            }
            cancelTimeout?.invoke()
            if (active === flow) active = null
            gate.leave(requestId)
            val answer = scanAnswer(outcome)
            if (answer is ScanAnswer.Failure) logFailure(outcome)
            // GMS callbacks, the timer and detach may run anywhere; replies go
            // on the main thread.
            reply.execute {
                when (answer) {
                    is ScanAnswer.Text -> result.success(answer.value)
                    is ScanAnswer.Failure ->
                        result.error(answer.code, "The scanner could not be opened", answer.details)
                }
            }
        }
        try {
            val started = newFlow(::finish)
            flow = started
            active = started
            cancelTimeout = timer.schedule(PREPARATION_TIMEOUT_MS) { started.timeoutPreparation() }
            started.start()
        } catch (error: Exception) {
            finish(BarcodeScanOutcome.Failure(error))
        }
    }

    override fun detach() {
        active?.dispose()
    }

    private fun logFailure(outcome: BarcodeScanOutcome) {
        val error = (outcome as? BarcodeScanOutcome.Failure)?.error ?: return
        // Only the class and a numeric code: never the scanned text.
        val code = (error as? BarcodeScanModuleInstallException)?.errorCode
            ?: (error as? MlKitException)?.errorCode
        runCatching { Log.w(TAG, "scan failed: ${error.javaClass.simpleName} code=$code") }
    }

    companion object {
        const val PREPARATION_TIMEOUT_MS = 30_000L
        private const val TAG = "PircScanner"

        fun create(activity: Activity) = ScannerChannel(newFlow = { done -> gmsScanFlow(activity, done) })

        private fun handlerTimer(): ScanTimer {
            val handler = Handler(Looper.getMainLooper())
            return ScanTimer { delay, action ->
                val runnable = Runnable(action)
                handler.postDelayed(runnable, delay)
                return@ScanTimer { handler.removeCallbacks(runnable) }
            }
        }
    }
}
