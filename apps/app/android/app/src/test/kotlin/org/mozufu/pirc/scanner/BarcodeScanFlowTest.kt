package org.mozufu.pirc.scanner

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BarcodeScanFlowTest {
    @Test
    fun availableModuleStartsScanWithoutInstallRequest() {
        val modules = FakeModules()
        val scanner = FakeScanner()
        val outcomes = mutableListOf<BarcodeScanOutcome>()
        val flow = BarcodeScanFlow(modules, scanner, outcomes::add)

        flow.start()
        modules.availabilityResult(true)

        assertEquals(0, modules.installCalls)
        assertEquals(1, scanner.startCalls)
        scanner.success("pirc://pair?token=sample")
        assertEquals(BarcodeScanOutcome.Success("pirc://pair?token=sample"), outcomes.single())
    }

    @Test
    fun waitsForInstallTerminalCompletionBeforeStartingScanner() {
        val modules = FakeModules()
        val scanner = FakeScanner()
        val outcomes = mutableListOf<BarcodeScanOutcome>()
        val flow = BarcodeScanFlow(modules, scanner, outcomes::add)

        flow.start()
        modules.availabilityResult(false)

        assertEquals(1, modules.installCalls)
        assertEquals(0, scanner.startCalls)
        assertTrue(outcomes.isEmpty())

        modules.installCompleted()

        assertEquals(1, scanner.startCalls)
        assertEquals(1, modules.unregisterCalls)
        scanner.cancelled()
        assertEquals(listOf(BarcodeScanOutcome.Cancelled), outcomes)
    }

    @Test
    fun duplicateAvailabilityAndInstallCallbacksCannotStartTwoScans() {
        val modules = FakeModules()
        val scanner = FakeScanner()
        val outcomes = mutableListOf<BarcodeScanOutcome>()
        val flow = BarcodeScanFlow(modules, scanner, outcomes::add)

        flow.start()
        modules.availabilityResult(false)
        modules.availabilityResult(true)
        modules.installCompleted()
        modules.installCompleted()

        assertEquals(1, modules.installCalls)
        assertEquals(1, scanner.startCalls)
        scanner.success("one result")
        scanner.success("late duplicate")
        assertEquals(listOf(BarcodeScanOutcome.Success("one result")), outcomes)
    }

    @Test
    fun moduleCancellationAndFailureDoNotStartScanner() {
        val modules = FakeModules()
        val scanner = FakeScanner()
        val outcomes = mutableListOf<BarcodeScanOutcome>()
        val flow = BarcodeScanFlow(modules, scanner, outcomes::add)

        flow.start()
        modules.availabilityResult(false)
        modules.installCancelled()
        modules.installFailed(IllegalStateException("module failed"))

        assertEquals(0, scanner.startCalls)
        assertEquals(listOf(BarcodeScanOutcome.Cancelled), outcomes)
    }

    @Test
    fun moduleInstallFailurePreservesOnlyNumericErrorCode() {
        val modules = FakeModules()
        val scanner = FakeScanner()
        val outcomes = mutableListOf<BarcodeScanOutcome>()
        val flow = BarcodeScanFlow(modules, scanner, outcomes::add)

        flow.start()
        modules.availabilityResult(false)
        modules.installFailed(BarcodeScanModuleInstallException(42))

        assertEquals(0, scanner.startCalls)
        val failure = outcomes.single() as BarcodeScanOutcome.Failure
        assertTrue(failure.error is BarcodeScanModuleInstallException)
        assertEquals(42, (failure.error as BarcodeScanModuleInstallException).errorCode)
        assertEquals("Google Play services scanner module install failed.", failure.error.message)
    }

    @Test
    fun disposeDuringInstallUnregistersAndIgnoresLateCompletion() {
        val modules = FakeModules()
        val scanner = FakeScanner()
        val outcomes = mutableListOf<BarcodeScanOutcome>()
        val flow = BarcodeScanFlow(modules, scanner, outcomes::add)

        flow.start()
        modules.availabilityResult(false)
        flow.dispose()
        modules.installCompleted()

        assertEquals(0, scanner.startCalls)
        assertEquals(1, modules.unregisterCalls)
        assertEquals(listOf(BarcodeScanOutcome.Cancelled), outcomes)
    }

    @Test
    fun preparationCancelPreventsLateInstallFromLaunchingScanner() {
        val modules = FakeModules()
        val scanner = FakeScanner()
        val outcomes = mutableListOf<BarcodeScanOutcome>()
        val flow = BarcodeScanFlow(modules, scanner, outcomes::add)

        flow.start()
        modules.availabilityResult(false)
        assertTrue(flow.cancelPreparation())
        modules.installCompleted()

        assertEquals(0, scanner.startCalls)
        assertEquals(1, modules.unregisterCalls)
        assertEquals(listOf(BarcodeScanOutcome.Cancelled), outcomes)
        assertFalse(flow.cancelPreparation())
    }

    @Test
    fun preparationCancelIsRejectedAfterScannerUiStarts() {
        val modules = FakeModules()
        val scanner = FakeScanner()
        val outcomes = mutableListOf<BarcodeScanOutcome>()
        val flow = BarcodeScanFlow(modules, scanner, outcomes::add)

        flow.start()
        modules.availabilityResult(true)

        assertEquals(1, scanner.startCalls)
        assertFalse(flow.cancelPreparation())
        scanner.success("scan still owns the scanner")
        assertEquals(listOf(BarcodeScanOutcome.Success("scan still owns the scanner")), outcomes)
    }

    @Test
    fun preparationTimeoutReleasesBusyGateAndIgnoresLateModuleStatus() {
        val modules = FakeModules()
        val scanner = FakeScanner()
        val gate = BarcodeScanBusyGate()
        val outcomes = mutableListOf<BarcodeScanOutcome>()
        assertTrue(gate.tryEnter("timeout-request"))
        val flow = BarcodeScanFlow(modules, scanner) { outcome ->
            outcomes += outcome
            gate.leave("timeout-request")
        }

        flow.start()
        modules.availabilityResult(false)
        assertTrue(flow.timeoutPreparation())
        modules.installCompleted()

        assertEquals(0, scanner.startCalls)
        assertEquals(1, modules.unregisterCalls)
        assertTrue(outcomes.single() is BarcodeScanOutcome.Failure)
        assertTrue((outcomes.single() as BarcodeScanOutcome.Failure).error is BarcodeScanPreparationTimeoutException)
        assertTrue(gate.tryEnter("next-request"))
    }

    @Test
    fun disposeDuringScanCompletesOnceAndIgnoresLateResult() {
        val modules = FakeModules()
        val scanner = FakeScanner()
        val outcomes = mutableListOf<BarcodeScanOutcome>()
        val flow = BarcodeScanFlow(modules, scanner, outcomes::add)

        flow.start()
        modules.availabilityResult(true)
        flow.dispose()
        scanner.success("late QR contents")
        scanner.failed(IllegalStateException("late scan failure"))

        assertEquals(1, scanner.startCalls)
        assertEquals(listOf(BarcodeScanOutcome.Cancelled), outcomes)
    }

    @Test
    fun synchronousInstallCompletionBeforeHandleReturnIsSafe() {
        val modules = FakeModules(completeInstallSynchronously = true)
        val scanner = FakeScanner()
        val outcomes = mutableListOf<BarcodeScanOutcome>()
        val flow = BarcodeScanFlow(modules, scanner, outcomes::add)

        flow.start()
        modules.availabilityResult(false)

        assertEquals(1, scanner.startCalls)
        assertEquals(1, modules.unregisterCalls)
        scanner.success("done")
        assertEquals(listOf(BarcodeScanOutcome.Success("done")), outcomes)
    }

    @Test
    fun busyGateAllowsOnlyOnePendingScanAndReopensAfterCompletion() {
        val gate = BarcodeScanBusyGate()

        assertTrue(gate.tryEnter("first"))
        assertFalse(gate.tryEnter("second"))
        assertFalse(gate.owns("second"))
        gate.leave("stale-first")
        assertFalse(gate.tryEnter("second"))
        gate.leave("first")
        assertTrue(gate.tryEnter("second"))
    }

    private class FakeModules(
        private val completeInstallSynchronously: Boolean = false,
    ) : BarcodeScanModuleInstaller {
        var installCalls = 0
        var unregisterCalls = 0
        private var availability: ((Boolean) -> Unit)? = null
        private var installed: (() -> Unit)? = null
        private var cancelled: (() -> Unit)? = null
        private var failure: ((Exception) -> Unit)? = null

        override fun areModulesAvailable(
            onResult: (Boolean) -> Unit,
            onFailure: (Exception) -> Unit,
        ) {
            availability = onResult
        }

        override fun install(
            onInstalled: () -> Unit,
            onCancelled: () -> Unit,
            onFailure: (Exception) -> Unit,
        ): BarcodeScanCancellation {
            installCalls++
            installed = onInstalled
            cancelled = onCancelled
            failure = onFailure
            if (completeInstallSynchronously) onInstalled()
            return BarcodeScanCancellation { unregisterCalls++ }
        }

        fun availabilityResult(available: Boolean) {
            availability?.invoke(available)
        }

        fun installCompleted() {
            installed?.invoke()
        }

        fun installCancelled() {
            cancelled?.invoke()
        }

        fun installFailed(error: Exception) {
            failure?.invoke(error)
        }
    }

    private class FakeScanner : BarcodeScanStarter {
        var startCalls = 0
        private var success: ((String?) -> Unit)? = null
        private var cancelled: (() -> Unit)? = null
        private var failure: ((Exception) -> Unit)? = null

        override fun start(
            onSuccess: (String?) -> Unit,
            onCancelled: () -> Unit,
            onFailure: (Exception) -> Unit,
        ) {
            startCalls++
            success = onSuccess
            cancelled = onCancelled
            failure = onFailure
        }

        fun success(value: String?) {
            success?.invoke(value)
        }

        fun cancelled() {
            cancelled?.invoke()
        }

        fun failed(error: Exception) {
            failure?.invoke(error)
        }
    }
}
