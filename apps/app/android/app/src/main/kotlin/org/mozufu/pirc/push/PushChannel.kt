package org.mozufu.pirc.push

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import org.mozufu.pirc.PlatformFeature
import org.mozufu.pirc.answerOn
import org.mozufu.pirc.background.BackgroundConfig
import org.mozufu.pirc.mainThreadExecutor

/**
 * `org.mozufu.pirc/push`: this phone's UnifiedPush registration and the background
 * client's target.
 * - `distributors` → `[{id, name}]`, the installed distributors;
 * - `status` → `{state, distributor, error, subscriptionId, timeZone}`, `state` being
 *   `off`, `connecting`, `on` or `failed`;
 * - `enable {distributor}` and `disable` → the status;
 * - `configure {gateway, clientId}`: where the background client connects (the app is
 *   online with a pairing); `forget {atGateway}`: the app unpairs, so push stops and the
 *   target goes. With `atGateway` (the default) it is called while the token is still
 *   stored, so the Gateway forgets the endpoint; without it nothing is sent (the Gateway
 *   refused the token, and the app may pair with another Gateway meanwhile).
 * - To Dart, `status` with the status whenever it changes.
 *
 * Errors: `INVALID` for bad arguments, `PUSH` when the Gateway or distributor refuses.
 */
class PushChannel internal constructor(
    private val registration: PushRegistration,
    private val config: BackgroundConfig,
    private val work: Executor = sharedWork,
    private val reply: Executor = mainThreadExecutor(),
    /** Time zone syncs, which wait on the network, never hold up the calls on [work]. */
    private val sync: Executor = sharedSync,
    private val timeZone: () -> String = { TimeZone.getDefault().id },
) : PlatformFeature {
    override val name = "push"

    @Volatile private var channel: MethodChannel? = null

    /** This channel's listener; another engine's channel may have replaced it since. */
    private val listener: (PushStatus) -> Unit = { status ->
        val map = statusMap(status)
        reply.execute { channel?.invokeMethod("status", map) }
    }

    override fun attached(channel: MethodChannel) {
        this.channel = channel
        synchronized(registration) { registration.onChange = listener }
    }

    override fun detach() {
        channel = null
        synchronized(registration) {
            if (registration.onChange === listener) registration.onChange = null
        }
    }

    /** The phone may be in another time zone now. */
    override fun foreground() {
        sync.execute { runCatching { registration.syncTimeZone() } }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "distributors" -> result.answerOn(work, reply, "PUSH") {
                registration.installed().map { (id, name) -> mapOf("id" to id, "name" to name) }
            }
            "status" -> result.answerOn(work, reply, "PUSH") { statusMap(registration.status()) }
            "enable" -> {
                val distributor = call.argument<String>("distributor")
                if (distributor.isNullOrEmpty()) return result.error("INVALID", "distributor is required", null)
                result.answerOn(work, reply, "PUSH") { statusMap(registration.enable(distributor)) }
            }
            "disable" -> result.answerOn(work, reply, "PUSH") { statusMap(registration.disable()) }
            "configure" -> {
                val gateway = call.argument<String>("gateway")
                val clientId = call.argument<String>("clientId")
                if (gateway.isNullOrEmpty() || clientId.isNullOrEmpty()) {
                    return result.error("INVALID", "gateway and clientId are required", null)
                }
                result.answerOn(work, reply, "PUSH") {
                    config.save(gateway, clientId)
                    sync.execute { runCatching { registration.syncTimeZone() } }
                    null
                }
            }
            "forget" -> {
                val atGateway = call.argument<Boolean>("atGateway") ?: true
                result.answerOn(work, reply, "PUSH") {
                    // Cleared first, disable has no Gateway to tell.
                    if (!atGateway) config.clear()
                    registration.forget()
                    config.clear()
                    null
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun statusMap(status: PushStatus) = status.toMap() + ("timeZone" to timeZone())

    companion object {
        /**
         * One worker for every channel instance: calls keep their order across engines
         * (a `forget` before a later `configure`), and no thread outlives a detached engine.
         */
        private val sharedWork: Executor by lazy { Executors.newSingleThreadExecutor() }

        private val sharedSync: Executor by lazy { Executors.newSingleThreadExecutor() }

        fun create(context: Context) = PushChannel(PushRegistration.get(context), BackgroundConfig.of(context))
    }
}
