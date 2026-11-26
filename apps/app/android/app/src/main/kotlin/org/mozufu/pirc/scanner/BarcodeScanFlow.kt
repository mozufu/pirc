package org.mozufu.pirc.scanner

/** A cancellable registration used while an optional scanner module is installing. */
internal fun interface BarcodeScanCancellation {
    fun cancel()
}

/** Checks/installs the optional scanner module without exposing GMS Tasks to the flow. */
internal interface BarcodeScanModuleInstaller {
    fun areModulesAvailable(onResult: (Boolean) -> Unit, onFailure: (Exception) -> Unit)

    fun install(
        onInstalled: () -> Unit,
        onCancelled: () -> Unit,
        onFailure: (Exception) -> Unit,
    ): BarcodeScanCancellation
}

/** Starts the privacy-preserving Google Play services scanner. */
internal interface BarcodeScanStarter {
    fun start(
        onSuccess: (String?) -> Unit,
        onCancelled: () -> Unit,
        onFailure: (Exception) -> Unit,
    )
}

internal sealed class BarcodeScanOutcome {
    data class Success(val value: String?) : BarcodeScanOutcome()
    object Cancelled : BarcodeScanOutcome()
    data class Failure(val error: Exception) : BarcodeScanOutcome()
}

internal class BarcodeScanPreparationTimeoutException :
    Exception("Google Play services scanner module preparation timed out.")

/** A sanitized, numeric failure reported by ModuleInstallStatusUpdate.STATE_FAILED. */
internal class BarcodeScanModuleInstallException(val errorCode: Int) :
    Exception("Google Play services scanner module install failed.")

/**
 * Runs one scan request. A module-install request is not treated as completion: the scanner
 * starts only after an availability check or a terminal successful install callback.
 */
internal class BarcodeScanFlow(
    private val modules: BarcodeScanModuleInstaller,
    private val scanner: BarcodeScanStarter,
    private val onComplete: (BarcodeScanOutcome) -> Unit,
) {
    private enum class Stage { NEW, CHECKING, INSTALLING, SCANNING, FINISHED }

    private val lock = Any()
    private var stage = Stage.NEW
    private var installCancellation: BarcodeScanCancellation? = null

    fun start() {
        if (!move(Stage.NEW, Stage.CHECKING)) return
        try {
            synchronized(lock) {
                if (stage != Stage.CHECKING) return
                modules.areModulesAvailable(
                    onResult = ::onAvailability,
                    onFailure = { finish(BarcodeScanOutcome.Failure(it)) },
                )
            }
        } catch (error: Exception) {
            finish(BarcodeScanOutcome.Failure(error))
        }
    }

    /** Activity destruction makes the pending method call a safe cancellation. */
    fun dispose() {
        finish(BarcodeScanOutcome.Cancelled)
    }

    /** Cancels only before the scanner UI has started. */
    fun cancelPreparation(): Boolean = finish(
        BarcodeScanOutcome.Cancelled,
        preparationOnly = true,
    )

    /** Ends a stuck module preparation without affecting an active scanner UI. */
    fun timeoutPreparation(): Boolean = finish(
        BarcodeScanOutcome.Failure(BarcodeScanPreparationTimeoutException()),
        preparationOnly = true,
    )

    private fun onAvailability(available: Boolean) {
        val nextStage = if (available) Stage.SCANNING else Stage.INSTALLING
        if (!move(Stage.CHECKING, nextStage)) return
        if (available) startScanner() else requestInstall()
    }

    private fun requestInstall() {
        val cancellation = try {
            synchronized(lock) {
                if (stage != Stage.INSTALLING) return
                modules.install(
                    onInstalled = ::onInstalled,
                    onCancelled = { finish(BarcodeScanOutcome.Cancelled) },
                    onFailure = { finish(BarcodeScanOutcome.Failure(it)) },
                )
            }
        } catch (error: Exception) {
            finish(BarcodeScanOutcome.Failure(error))
            return
        }
        // The fake or platform API may complete synchronously before install() returns.
        val cancelNow = synchronized(lock) {
            if (stage == Stage.INSTALLING) {
                installCancellation = cancellation
                false
            } else {
                true
            }
        }
        if (cancelNow) cancelQuietly(cancellation)
    }

    private fun onInstalled() {
        val cancellation = synchronized(lock) {
            if (stage != Stage.INSTALLING) return
            stage = Stage.SCANNING
            installCancellation.also { installCancellation = null }
        }
        cancellation?.let(::cancelQuietly)
        startScanner()
    }

    private fun startScanner() {
        try {
            synchronized(lock) {
                if (stage != Stage.SCANNING) return
                scanner.start(
                    onSuccess = { finish(BarcodeScanOutcome.Success(it)) },
                    onCancelled = { finish(BarcodeScanOutcome.Cancelled) },
                    onFailure = { finish(BarcodeScanOutcome.Failure(it)) },
                )
            }
        } catch (error: Exception) {
            finish(BarcodeScanOutcome.Failure(error))
        }
    }

    private fun move(expected: Stage, next: Stage): Boolean = synchronized(lock) {
        if (stage != expected) return@synchronized false
        stage = next
        true
    }

    private fun finish(
        outcome: BarcodeScanOutcome,
        preparationOnly: Boolean = false,
    ): Boolean {
        var accepted = false
        val cancellation = synchronized(lock) {
            if (stage == Stage.FINISHED || (preparationOnly && stage == Stage.SCANNING)) {
                return@synchronized null
            }
            accepted = true
            stage = Stage.FINISHED
            installCancellation.also { installCancellation = null }
        }
        if (!accepted) return false
        cancellation?.let(::cancelQuietly)
        onComplete(outcome)
        return true
    }

    private fun cancelQuietly(cancellation: BarcodeScanCancellation) {
        try {
            cancellation.cancel()
        } catch (_: Exception) {
            // Cleanup must not replace the scan's already-selected terminal result.
        }
    }
}

/** Keeps the MethodChannel's single scanner slot closed until its result is delivered. */
internal class BarcodeScanBusyGate {
    private var activeRequestId: String? = null

    @Synchronized
    fun tryEnter(requestId: String): Boolean {
        if (activeRequestId != null) return false
        activeRequestId = requestId
        return true
    }

    @Synchronized
    fun owns(requestId: String): Boolean = activeRequestId == requestId

    @Synchronized
    fun leave(requestId: String) {
        if (activeRequestId != requestId) return
        activeRequestId = null
    }
}
