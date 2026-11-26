package org.mozufu.pirc.push

import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import org.json.JSONObject
import org.mozufu.pirc.background.BackgroundConfig
import org.mozufu.pirc.background.BackgroundTarget
import org.mozufu.pirc.background.long
import org.mozufu.pirc.background.text
import org.mozufu.pirc.credentials.KeystoreCredentialStore
import org.unifiedpush.android.connector.UnifiedPush

/** Where this phone stands with push. [state] is `off`, `connecting`, `on` or `failed`. */
data class PushStatus(
    val state: String,
    /** The distributor's package, when one is chosen. */
    val distributor: String?,
    /** Why registration failed; for logs and the settings page. */
    val error: String?,
    /** This phone's target at the Gateway, once it has the endpoint. */
    val subscriptionId: String?,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "state" to state,
        "distributor" to distributor,
        "error" to error,
        "subscriptionId" to subscriptionId,
    )
}

/** The UnifiedPush connector, behind an interface so tests need no distributor. */
interface PushDistributors {
    /** The packages of the installed distributors. */
    fun installed(): List<String>

    /** The distributor's name as the launcher shows it. */
    fun label(distributor: String): String

    fun select(distributor: String)

    /** Registers [instance] with the selected distributor, signed for [vapid]. */
    fun register(instance: String, vapid: String)

    fun unregister(instance: String)
}

class UnifiedPushDistributors(private val context: Context) : PushDistributors {
    override fun installed(): List<String> = UnifiedPush.getDistributors(context)

    override fun label(distributor: String): String = try {
        val pm = context.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(distributor, 0)).toString()
    } catch (_: PackageManager.NameNotFoundException) {
        distributor
    }

    override fun select(distributor: String) = UnifiedPush.saveDistributor(context, distributor)

    override fun register(instance: String, vapid: String) =
        UnifiedPush.register(context, instance, null, vapid)

    override fun unregister(instance: String) = UnifiedPush.unregister(context, instance)
}

/**
 * This phone's UnifiedPush registration, as the old app's `PushRegistration.kt` did it:
 * the distributor (ntfy, …) gives an endpoint with Web Push keys, which goes to
 * `POST /api/push/subscriptions` with `kind: unifiedpush`; the Gateway then pushes there,
 * encrypted for this app.
 *
 * Each enable is a new connector instance. Callbacks of an older instance (a retired
 * one) are ignored, an endpoint that arrives after disable or a new pairing is deleted
 * at the Gateway again, and old instances are unregistered only after the new one is
 * registered.
 *
 * A new endpoint is a new target at the Gateway, which starts with default preferences.
 * So the preferences of the target being replaced are read first and set on the new one
 * before the app hears of it, together with the phone's time zone; the old endpoint is
 * deleted at the Gateway only once the new one is saved there. Calls that reach the
 * Gateway block: run them off the main thread.
 */
class PushRegistration internal constructor(
    private val prefs: SharedPreferences,
    private val config: BackgroundConfig,
    private val distributors: PushDistributors,
    private val gatewayFor: (BackgroundTarget) -> PushGateway,
    private val work: Executor,
    private val deviceName: String = "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
    private val timeZone: () -> String = { TimeZone.getDefault().id },
) {
    private val lock = Any()

    /** Told after every change, on any thread. */
    @Volatile var onChange: ((PushStatus) -> Unit)? = null

    fun status(): PushStatus = synchronized(lock) {
        val error = prefs.getString(ERROR, null)
        val endpoint = prefs.getString(ENDPOINT, null)
        PushStatus(
            state = when {
                !prefs.getBoolean(ENABLED, false) -> "off"
                error != null -> "failed"
                endpoint != null -> "on"
                else -> "connecting"
            },
            distributor = prefs.getString(DISTRIBUTOR, null),
            error = error,
            subscriptionId = prefs.getString(SUBSCRIPTION, null),
        )
    }

    /** The installed distributors with their names, in the connector's order. */
    fun installed(): List<Pair<String, String>> = distributors.installed().map { it to distributors.label(it) }

    /**
     * Registers with [distributor], signed for the Gateway's VAPID key. The endpoint
     * arrives later in [onEndpoint]. Throws when the app is not paired or the Gateway or
     * the distributor refuses; a registration that worked before is then kept.
     */
    fun enable(distributor: String): PushStatus {
        val target = config.read() ?: throw IllegalStateException("This device is not paired")
        require(distributor in distributors.installed()) { "The distributor is not installed" }
        val gateway = gatewayFor(target)
        val remembered = prefs.getString(SUBSCRIPTION, null)
        remembered?.let { remember(gateway, it, target.pairingStamp) }
        val attempt = PushRegistrationAttempt(UUID.randomUUID().toString(), target.pairingStamp)
        val previous = synchronized(lock) {
            val previous = Previous(
                instance = prefs.getString(INSTANCE, null),
                endpoint = prefs.getString(ENDPOINT, null),
                subscription = prefs.getString(SUBSCRIPTION, null),
                distributor = prefs.getString(DISTRIBUTOR, null),
                stamp = prefs.getString(STAMP, null),
            )
            val retired = retiredLocked() + listOfNotNull(previous.instance)
            // The old endpoint stays at the Gateway until the new one is saved there.
            val old = oldEndpointsLocked(target.pairingStamp) + listOfNotNull(previous.endpoint.takeIf { previous.stamp == target.pairingStamp })
            prefs.edit()
                .putBoolean(ENABLED, true)
                .putString(INSTANCE, attempt.instance)
                .putString(STAMP, attempt.pairingStamp)
                .putString(DISTRIBUTOR, distributor)
                .putStringSet(RETIRED, retired)
                .putStringSet(OLD_ENDPOINTS, old)
                .putString(OLD_STAMP, target.pairingStamp)
                .remove(ENDPOINT)
                .remove(SUBSCRIPTION)
                .remove(ERROR)
                .commit()
            previous
        }
        // A renewed endpoint replaced the target between the read and the lock: read the
        // new one. Its target stays until ours is saved, and ours cannot arrive before
        // the register below.
        previous.subscription?.takeIf { it != remembered }?.let { remember(gateway, it, target.pairingStamp) }
        changed()
        try {
            val key = gateway.publicKey()
            // A distributor that fails later (onRegistrationFailed), after the old
            // instance was retired here, leaves push failed; the user turns it on again.
            val replacement = registerBeforeRetiring(
                activeInstance = attempt.instance,
                retiredInstances = synchronized(lock) { retiredLocked() },
                register = {
                    // The check and the register are one step against a disable meanwhile.
                    synchronized(lock) {
                        if (snapshot().accepts(attempt)) {
                            distributors.select(distributor)
                            distributors.register(attempt.instance, key)
                            true
                        } else {
                            false
                        }
                    }
                },
                unregister = distributors::unregister,
            )
            if (replacement.registered) {
                synchronized(lock) {
                    if (snapshot().accepts(attempt)) {
                        prefs.edit().putStringSet(RETIRED, replacement.pendingRetiredInstances).commit()
                    }
                }
            }
        } catch (error: Exception) {
            restoreOrFail(attempt, previous, error.message ?: "Could not register with the distributor")
            throw error
        }
        return status()
    }

    /** What [enable] replaces, to put back when the new registration never started. */
    private data class Previous(
        val instance: String?,
        val endpoint: String?,
        val subscription: String?,
        val distributor: String?,
        val stamp: String?,
    )

    /**
     * Nothing was registered for [attempt]. A registration that had an endpoint is put
     * back as it was (its instance was not unregistered, its target not deleted);
     * otherwise the status says why it failed.
     */
    private fun restoreOrFail(attempt: PushRegistrationAttempt, previous: Previous, reason: String) {
        synchronized(lock) {
            if (!snapshot().accepts(attempt)) return
            if (previous.instance != null && previous.endpoint != null && previous.stamp == attempt.pairingStamp) {
                prefs.edit()
                    .putString(INSTANCE, previous.instance)
                    .putString(ENDPOINT, previous.endpoint)
                    .putString(SUBSCRIPTION, previous.subscription)
                    .putString(DISTRIBUTOR, previous.distributor)
                    .putStringSet(RETIRED, retiredLocked() - previous.instance)
                    .putStringSet(OLD_ENDPOINTS, oldEndpointsLocked(attempt.pairingStamp) - previous.endpoint)
                    .remove(ERROR)
                    .commit()
            } else {
                prefs.edit().putString(ERROR, reason).commit()
            }
        }
        changed()
    }

    /**
     * Stops push: at the distributor and, while the token is still there, at the Gateway.
     * An instance whose unregister fails, or an endpoint whose delete fails, is kept to be
     * tried again; the preferences are kept for the next enable.
     */
    fun disable(): PushStatus = disable(keepPreferences = true)

    /** [keepPreferences]: read the target's preferences first, for the next enable. */
    private fun disable(keepPreferences: Boolean): PushStatus {
        val target = config.read()
        val subscription = prefs.getString(SUBSCRIPTION, null)
        if (keepPreferences && target != null && subscription != null) {
            remember(gatewayFor(target), subscription, target.pairingStamp)
        }
        val (instances, endpoints) = synchronized(lock) {
            val instances = retiredLocked() + listOfNotNull(prefs.getString(INSTANCE, null))
            val sameStamp = prefs.getString(STAMP, null) == target?.pairingStamp
            val endpoints = (target?.let { oldEndpointsLocked(it.pairingStamp) } ?: emptySet()) +
                listOfNotNull(prefs.getString(ENDPOINT, null).takeIf { sameStamp })
            // Callbacks are refused from here on, before the distributor or Gateway answers.
            clearRegistrationLocked()
                .putStringSet(RETIRED, instances)
                .apply { if (target != null) putStringSet(OLD_ENDPOINTS, endpoints).putString(OLD_STAMP, target.pairingStamp) }
                .commit()
            instances to endpoints
        }
        changed()
        val unregistered = instances.filter { instance -> runCatching { distributors.unregister(instance) }.isSuccess }
        synchronized(lock) { prefs.edit().putStringSet(RETIRED, retiredLocked() - unregistered.toSet()).commit() }
        if (target != null) deleteOld(gatewayFor(target), target.pairingStamp, endpoints)
        return status()
    }

    /** The app unpairs: push stops, and what belonged to that pairing at the Gateway is forgotten. */
    fun forget(): PushStatus {
        // Unpairing waits on this: the endpoint is deleted without reading anything first.
        disable(keepPreferences = false)
        synchronized(lock) {
            prefs.edit().remove(OLD_ENDPOINTS).remove(OLD_STAMP).remove(CARRY).remove(CARRY_STAMP).commit()
        }
        return status()
    }

    /** The distributor gave [instance] an endpoint; it goes to the Gateway. */
    fun onEndpoint(instance: String, url: String, p256dh: String?, auth: String?) {
        if (p256dh.isNullOrEmpty() || auth.isNullOrEmpty()) {
            fail(instance, "The distributor gave no Web Push keys; it needs UnifiedPush 3")
            return
        }
        work.execute { saveEndpoint(instance, url, p256dh, auth) }
    }

    private fun saveEndpoint(instance: String, url: String, p256dh: String, auth: String) {
        val target = config.read() ?: return
        val attempt = PushRegistrationAttempt(instance, target.pairingStamp)
        if (!synchronized(lock) { snapshot().accepts(attempt) }) return
        val gateway = gatewayFor(target)
        // A renewed endpoint replaces this instance's own target: keep its preferences,
        // unless they are still waiting to be set on it.
        prefs.getString(SUBSCRIPTION, null)?.let { current ->
            val carry = carried(target.pairingStamp)
            if (carry?.text("from") != current && carry?.text("to") != current) remember(gateway, current, target.pairingStamp)
        }
        try {
            var saved = gateway.subscribe(url, p256dh, auth, deviceName)
            val id = saved.text("id") ?: throw PushGatewayException(null, null, "The gateway gave no subscription id")
            // Before the app hears of the target: the preferences it replaces, and the
            // phone's zone, so the settings page never meets a revision it did not read.
            val carry = carried(target.pairingStamp)?.takeIf { it.text("from") != id }
            val fields = carryFields(carry, saved.text("timeZone"))
            var carriedOver = true
            if (fields.length() > 0) {
                runCatching { saved = gateway.update(id, saved.long("revision") ?: 0, fields) }
                    .onFailure {
                        carriedOver = false
                        Log.w(TAG, "Could not carry the preferences over: ${it.message}")
                    }
            }
            var previous: String? = null
            val accepted = synchronized(lock) {
                if (snapshot().shouldCompensate(attempt)) {
                    false
                } else {
                    previous = prefs.getString(ENDPOINT, null)?.takeIf { it != url }
                    val edit = prefs.edit()
                        .putString(ENDPOINT, url)
                        .putString(SUBSCRIPTION, id)
                        .remove(ERROR)
                    // A replaced endpoint is queued before it is deleted, so a failed
                    // delete is tried again.
                    previous?.let { addOldLocked(edit, target.pairingStamp, it) }
                    if (carriedOver || carry == null) {
                        edit.remove(CARRY).remove(CARRY_STAMP)
                    } else {
                        // Set on this target at the next sync (foreground).
                        edit.putString(CARRY, carry.put("to", id).toString())
                    }
                    edit.commit()
                    true
                }
            }
            if (!accepted) {
                // Disabled or paired again while the Gateway took it: take it back.
                runCatching { gateway.unsubscribe(url) }
                return
            }
            changed()
            // The targets this one replaces go only now that it is saved.
            val old = synchronized(lock) { oldEndpointsLocked(target.pairingStamp) }
            deleteOld(gateway, target.pairingStamp, old - url)
        } catch (error: Exception) {
            fail(instance, error.message ?: "Could not register this endpoint")
        }
    }

    /**
     * Sets the phone's time zone on its target when it differs (the app starts or comes to
     * the foreground; the phone may have travelled), and preferences carried over from a
     * replaced target whose PATCH failed.
     */
    fun syncTimeZone() {
        val target = config.read() ?: return
        val id = synchronized(lock) { prefs.getString(SUBSCRIPTION, null).takeIf { prefs.getString(STAMP, null) == target.pairingStamp } } ?: return
        val gateway = gatewayFor(target)
        val current = runCatching { gateway.target(id) }.getOrNull() ?: return
        val carry = carried(target.pairingStamp)?.takeIf { it.text("to") == id }
        val fields = carryFields(carry, current.text("timeZone"))
        if (fields.length() == 0) return
        runCatching { gateway.update(id, current.long("revision") ?: 0, fields) }
            .onSuccess {
                if (carry != null) {
                    synchronized(lock) {
                        if (carried(target.pairingStamp)?.text("to") == id) prefs.edit().remove(CARRY).remove(CARRY_STAMP).commit()
                    }
                }
                changed()
            }
            .onFailure { Log.w(TAG, "Could not set the time zone: ${it.message}") }
    }

    /**
     * The PATCH fields for a target whose zone is [targetZone]: the [carry]'s preferences,
     * then always the phone's zone after them when anything is carried or the zone differs.
     */
    private fun carryFields(carry: JSONObject?, targetZone: String?): JSONObject {
        val fields = JSONObject()
        carry?.optJSONObject("preferences")?.let { carried -> for (key in carried.keys()) fields.put(key, carried.get(key)) }
        val zone = timeZone()
        if (fields.length() > 0 || targetZone != zone) fields.put("timeZone", zone)
        return fields
    }

    /** Registration of [instance] failed; ignored for a retired instance or once an endpoint is saved. */
    fun fail(instance: String, reason: String) {
        synchronized(lock) {
            if (!snapshot().acceptsCallback(instance)) return
            if (prefs.getString(ENDPOINT, null) != null) return
            prefs.edit().putString(ERROR, reason).commit()
        }
        changed()
    }

    /**
     * The distributor dropped [instance] (it was uninstalled, or the user removed us
     * there). Its endpoint is deleted at the Gateway too, its preferences kept.
     */
    fun onUnregistered(instance: String) {
        val (endpoint, subscription, stamp) = synchronized(lock) {
            if (!snapshot().acceptsCallback(instance)) return
            val endpoint = prefs.getString(ENDPOINT, null)
            val subscription = prefs.getString(SUBSCRIPTION, null)
            val stamp = prefs.getString(STAMP, null)
            val edit = clearRegistrationLocked().putStringSet(RETIRED, retiredLocked() - instance)
            // Queued first, so a failed delete is tried again.
            if (endpoint != null && stamp != null) addOldLocked(edit, stamp, endpoint)
            edit.commit()
            Triple(endpoint, subscription, stamp)
        }
        changed()
        if (endpoint == null || stamp == null) return
        work.execute {
            val target = config.read()?.takeIf { it.pairingStamp == stamp } ?: return@execute
            val gateway = gatewayFor(target)
            subscription?.let { remember(gateway, it, target.pairingStamp) }
            deleteOld(gateway, target.pairingStamp, setOf(endpoint))
        }
    }

    /** Whether a message to [instance] belongs to the current registration and pairing. */
    fun acceptsMessage(instance: String): Boolean = synchronized(lock) {
        val snapshot = snapshot()
        snapshot.acceptsCallback(instance) && snapshot.pairingStamp == prefs.getString(STAMP, null)
    }

    /** Reads the preferences of target [id] to set on the next one. Best effort. */
    private fun remember(gateway: PushGateway, id: String, stamp: String) {
        val current = runCatching { gateway.target(id) }.getOrNull() ?: return
        val preferences = JSONObject()
        for (key in CARRIED) {
            if (current.has(key)) preferences.put(key, current.get(key))
        }
        val carry = JSONObject().put("from", id).put("preferences", preferences)
        synchronized(lock) { prefs.edit().putString(CARRY, carry.toString()).putString(CARRY_STAMP, stamp).commit() }
    }

    private fun carried(stamp: String): JSONObject? = synchronized(lock) {
        if (prefs.getString(CARRY_STAMP, null) != stamp) return null
        prefs.getString(CARRY, null)?.let { runCatching { JSONObject(it) }.getOrNull() }
    }

    /** Deletes [endpoints] at the Gateway; those that fail stay to be tried again. */
    private fun deleteOld(gateway: PushGateway, stamp: String, endpoints: Set<String>) {
        val deleted = endpoints.filter { runCatching { gateway.unsubscribe(it) }.isSuccess }.toSet()
        if (deleted.isEmpty()) return
        synchronized(lock) {
            if (prefs.getString(OLD_STAMP, null) == stamp) {
                prefs.edit().putStringSet(OLD_ENDPOINTS, oldEndpointsLocked(stamp) - deleted).commit()
            }
        }
    }

    /** Queues [endpoint] of pairing [stamp] to be deleted at the Gateway. */
    private fun addOldLocked(edit: SharedPreferences.Editor, stamp: String, endpoint: String) {
        edit.putStringSet(OLD_ENDPOINTS, oldEndpointsLocked(stamp) + endpoint).putString(OLD_STAMP, stamp)
    }

    private fun retiredLocked(): Set<String> = prefs.getStringSet(RETIRED, emptySet()).orEmpty().toSet()

    private fun oldEndpointsLocked(stamp: String): Set<String> =
        if (prefs.getString(OLD_STAMP, null) == stamp) prefs.getStringSet(OLD_ENDPOINTS, emptySet()).orEmpty().toSet() else emptySet()

    /** Removes the current registration; retired instances, old endpoints and carried preferences stay. */
    private fun clearRegistrationLocked(): SharedPreferences.Editor = prefs.edit()
        .remove(ENABLED)
        .remove(INSTANCE)
        .remove(STAMP)
        .remove(DISTRIBUTOR)
        .remove(ENDPOINT)
        .remove(SUBSCRIPTION)
        .remove(ERROR)

    private fun snapshot() = PushRegistrationSnapshot(
        enabled = prefs.getBoolean(ENABLED, false),
        instance = prefs.getString(INSTANCE, null),
        pairingStamp = config.read()?.pairingStamp,
    )

    private fun changed() {
        val listener = onChange ?: return
        listener(status())
    }

    companion object {
        private const val TAG = "PircPush"
        private const val PREFS = "push"
        private const val ENABLED = "enabled"
        private const val INSTANCE = "instance"
        private const val STAMP = "pairingStamp"
        private const val RETIRED = "retiredInstances"
        private const val ENDPOINT = "endpoint"
        private const val SUBSCRIPTION = "subscriptionId"
        private const val DISTRIBUTOR = "distributor"
        private const val ERROR = "error"

        /** Gateway endpoints replaced by a newer one, deleted once it is saved. */
        private const val OLD_ENDPOINTS = "oldEndpoints"
        private const val OLD_STAMP = "oldEndpointsPairing"

        /** `{from, preferences}`: the preferences of a replaced target, for the next one. */
        private const val CARRY = "carriedPreferences"
        private const val CARRY_STAMP = "carriedPreferencesPairing"

        /** What a new target takes over from the one it replaces. */
        private val CARRIED = listOf("levels", "quietHours", "timeZone", "lockScreen", "digestAt")

        @Volatile private var shared: PushRegistration? = null

        /** The app's one registration; the push service and the channel share it. */
        fun get(context: Context): PushRegistration = shared ?: synchronized(this) {
            shared ?: run {
                val app = context.applicationContext
                val store = KeystoreCredentialStore.create(app)
                PushRegistration(
                    prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE),
                    config = BackgroundConfig.of(app),
                    distributors = UnifiedPushDistributors(app),
                    gatewayFor = { target -> PushGateway(target.gateway, store::read) },
                    work = Executors.newSingleThreadExecutor(),
                ).also { shared = it }
            }
        }
    }
}
