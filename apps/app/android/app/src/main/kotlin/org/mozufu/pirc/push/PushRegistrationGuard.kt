package org.mozufu.pirc.push

/** One asynchronous registration: its connector instance and the pairing it began under. */
internal data class PushRegistrationAttempt(
    val instance: String,
    val pairingStamp: String,
)

/** The stored registration state that service callbacks are checked against. */
internal data class PushRegistrationSnapshot(
    val enabled: Boolean,
    val instance: String?,
    /** The pairing now; null when the app is not paired. */
    val pairingStamp: String?,
) {
    fun acceptsCallback(callbackInstance: String): Boolean =
        enabled && !instance.isNullOrBlank() && callbackInstance == instance

    fun accepts(attempt: PushRegistrationAttempt): Boolean =
        acceptsCallback(attempt.instance) && pairingStamp == attempt.pairingStamp

    /** A subscription the Gateway took for an attempt that is no longer current is deleted again. */
    fun shouldCompensate(attempt: PushRegistrationAttempt): Boolean = !accepts(attempt)
}

/** What [registerBeforeRetiring] did. */
internal data class PushRegistrationReplacementResult(
    val registered: Boolean,
    /** Old instances whose unregister failed; tried again on the next enable or disable. */
    val pendingRetiredInstances: Set<String>,
)

/**
 * Registers the replacement before retiring old instances: the connector forgets its
 * saved distributor when unregister removes its last registration, so a later register
 * would have no distributor to go to. An unregister that fails stays queued.
 */
internal fun registerBeforeRetiring(
    activeInstance: String,
    retiredInstances: Set<String>,
    register: () -> Boolean,
    unregister: (String) -> Unit,
): PushRegistrationReplacementResult {
    if (!register()) {
        return PushRegistrationReplacementResult(false, retiredInstances - activeInstance)
    }
    val pending = mutableSetOf<String>()
    for (instance in retiredInstances) {
        if (instance == activeInstance) continue
        if (runCatching { unregister(instance) }.isFailure) pending += instance
    }
    return PushRegistrationReplacementResult(true, pending)
}
