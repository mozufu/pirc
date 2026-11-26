package org.mozufu.pirc.scanner

import android.app.Activity
import com.google.android.gms.common.moduleinstall.InstallStatusListener
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
import com.google.android.gms.common.moduleinstall.ModuleInstallStatusUpdate
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScanner
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import java.util.concurrent.atomic.AtomicBoolean

/** A scan flow on the Google Play services code scanner, for QR codes only. */
internal fun gmsScanFlow(activity: Activity, onComplete: (BarcodeScanOutcome) -> Unit): BarcodeScanFlow {
    val options = GmsBarcodeScannerOptions.Builder()
        .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
        .build()
    val scanner = GmsBarcodeScanning.getClient(activity, options)
    return BarcodeScanFlow(
        modules = GmsBarcodeScanModuleInstaller(activity, scanner),
        scanner = GmsBarcodeScanStarter(scanner),
        onComplete = onComplete,
    )
}

/** Checks for the optional scanner module and installs it (from the old app). */
private class GmsBarcodeScanModuleInstaller(
    activity: Activity,
    private val scanner: GmsBarcodeScanner,
) : BarcodeScanModuleInstaller {
    private val client = ModuleInstall.getClient(activity)

    override fun areModulesAvailable(
        onResult: (Boolean) -> Unit,
        onFailure: (Exception) -> Unit,
    ) {
        client.areModulesAvailable(scanner)
            .addOnSuccessListener { onResult(it.areModulesAvailable()) }
            .addOnFailureListener(onFailure)
    }

    override fun install(
        onInstalled: () -> Unit,
        onCancelled: () -> Unit,
        onFailure: (Exception) -> Unit,
    ): BarcodeScanCancellation {
        val terminal = AtomicBoolean(false)
        val registered = AtomicBoolean(true)
        fun installed() {
            if (terminal.compareAndSet(false, true)) onInstalled()
        }
        fun cancelled() {
            if (terminal.compareAndSet(false, true)) onCancelled()
        }
        fun failed(error: Exception) {
            if (terminal.compareAndSet(false, true)) onFailure(error)
        }

        val listener = object : InstallStatusListener {
            override fun onInstallStatusUpdated(update: ModuleInstallStatusUpdate) {
                when (update.installState) {
                    ModuleInstallStatusUpdate.InstallState.STATE_COMPLETED -> installed()
                    ModuleInstallStatusUpdate.InstallState.STATE_CANCELED -> cancelled()
                    ModuleInstallStatusUpdate.InstallState.STATE_FAILED -> failed(
                        BarcodeScanModuleInstallException(update.errorCode),
                    )
                }
            }
        }
        val request = ModuleInstallRequest.newBuilder()
            .addApi(scanner)
            .setListener(listener)
            .build()
        try {
            client.installModules(request)
                .addOnSuccessListener { response ->
                    if (response.areModulesAlreadyInstalled()) installed()
                }
                .addOnFailureListener(::failed)
        } catch (error: Exception) {
            if (registered.compareAndSet(true, false)) client.unregisterListener(listener)
            throw error
        }

        return BarcodeScanCancellation {
            if (registered.compareAndSet(true, false)) {
                client.unregisterListener(listener)
            }
        }
    }
}

/** Starts the scanner screen of Google Play services; the app needs no camera permission. */
private class GmsBarcodeScanStarter(
    private val scanner: GmsBarcodeScanner,
) : BarcodeScanStarter {
    override fun start(
        onSuccess: (String?) -> Unit,
        onCancelled: () -> Unit,
        onFailure: (Exception) -> Unit,
    ) {
        scanner.startScan()
            .addOnSuccessListener { onSuccess(it.rawValue) }
            .addOnCanceledListener { onCancelled() }
            .addOnFailureListener(onFailure)
    }
}
