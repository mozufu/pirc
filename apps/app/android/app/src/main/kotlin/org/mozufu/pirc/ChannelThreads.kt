package org.mozufu.pirc

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor

/** Runs posted work on the main thread, where channel replies must go. */
fun mainThreadExecutor(): Executor {
    val handler = Handler(Looper.getMainLooper())
    return Executor { handler.post(it) }
}

/**
 * Runs [action] on [work] and answers on [reply]: its value, `INVALID` for an
 * [IllegalArgumentException] (bad arguments from Dart), or [code] for any other failure.
 * The message is for logs; Dart shows its own text.
 */
fun MethodChannel.Result.answerOn(work: Executor, reply: Executor, code: String, action: () -> Any?) {
    work.execute {
        val outcome = runCatching(action)
        reply.execute {
            outcome.fold(
                onSuccess = { success(it) },
                onFailure = {
                    val failure = if (it is IllegalArgumentException) "INVALID" else code
                    error(failure, it.message ?: it.javaClass.simpleName, null)
                },
            )
        }
    }
}
