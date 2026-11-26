package org.mozufu.pirc

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor

/** Runs work and replies on the calling thread. */
val direct = Executor { it.run() }

/** What a channel answered to one call. */
class Answer : MethodChannel.Result {
    var value: Any? = null
    var errorCode: String? = null
    var notImplemented = false
    var answered = false

    override fun success(result: Any?) {
        check(!answered) { "answered twice" }
        answered = true
        value = result
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        check(!answered) { "answered twice" }
        answered = true
        this.errorCode = errorCode
    }

    override fun notImplemented() {
        check(!answered) { "answered twice" }
        answered = true
        notImplemented = true
    }
}

fun MethodChannel.MethodCallHandler.call(method: String, args: Map<String, Any?>? = null): Answer =
    Answer().also { onMethodCall(MethodCall(method, args), it) }
