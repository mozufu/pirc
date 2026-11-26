package org.mozufu.pirc.credentials

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.mozufu.pirc.PlatformFeature

/**
 * `org.mozufu.pirc/credentials`: `read` → the token or null, `save {token}`, `delete`.
 * The Keystore work runs on one background thread, in call order; replies go back on
 * [reply] (the main thread).
 */
class CredentialsChannel(
    private val store: CredentialStore,
    private val work: Executor = Executors.newSingleThreadExecutor(),
    private val reply: Executor = mainThread(),
) : PlatformFeature {
    override val name = "credentials"

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val action: () -> Any? = when (call.method) {
            "read" -> store::read
            "save" -> {
                val token = call.argument<String>("token")
                if (token.isNullOrEmpty()) {
                    result.error("INVALID", "token is required", null)
                    return
                }
                { store.save(token); null }
            }
            "delete" -> { { store.delete(); null } }
            else -> {
                result.notImplemented()
                return
            }
        }
        work.execute {
            val outcome = runCatching(action)
            reply.execute {
                outcome.fold(
                    onSuccess = { result.success(it) },
                    // Never put the token or the key in an error message.
                    onFailure = { result.error("CREDENTIALS", it.javaClass.simpleName, null) },
                )
            }
        }
    }

    override fun detach() {
        (work as? ExecutorService)?.shutdown()
    }

    private companion object {
        fun mainThread(): Executor {
            val handler = Handler(Looper.getMainLooper())
            return Executor { handler.post(it) }
        }
    }
}
