package org.mozufu.pirc.scanner

import com.google.mlkit.common.MlKitException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mozufu.pirc.call
import org.mozufu.pirc.direct
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ScannerChannelTest {
    private class Modules(val available: Boolean = true) : BarcodeScanModuleInstaller {
        override fun areModulesAvailable(onResult: (Boolean) -> Unit, onFailure: (Exception) -> Unit) =
            onResult(available)

        override fun install(
            onInstalled: () -> Unit,
            onCancelled: () -> Unit,
            onFailure: (Exception) -> Unit,
        ) = BarcodeScanCancellation {}
    }

    /** Holds the scanner's callbacks until the test answers. */
    private class Screen : BarcodeScanStarter {
        var success: ((String?) -> Unit)? = null
        var cancelled: (() -> Unit)? = null
        var failure: ((Exception) -> Unit)? = null

        override fun start(onSuccess: (String?) -> Unit, onCancelled: () -> Unit, onFailure: (Exception) -> Unit) {
            success = onSuccess
            cancelled = onCancelled
            failure = onFailure
        }
    }

    private class Timer : ScanTimer {
        var action: (() -> Unit)? = null
        var cancelled = 0

        override fun schedule(delayMillis: Long, action: () -> Unit): () -> Unit {
            assertEquals(ScannerChannel.PREPARATION_TIMEOUT_MS, delayMillis)
            this.action = action
            return { cancelled++ }
        }
    }

    private val screen = Screen()
    private val timer = Timer()

    private fun channel(modules: Modules = Modules()) =
        ScannerChannel(newFlow = { done -> BarcodeScanFlow(modules, screen, done) }, timer = timer, reply = direct)

    @Test fun aScannedCodeIsAnsweredAsText() {
        val channel = channel()
        assertEquals("scanner", channel.name)
        val answer = channel.call("scan")
        assertFalse(answer.answered)
        screen.success!!("pirc://pair?url=https%3A%2F%2Fgateway.test&token=t")
        assertEquals("pirc://pair?url=https%3A%2F%2Fgateway.test&token=t", answer.value)
        assertEquals(1, timer.cancelled)
    }

    @Test fun closingTheScannerAnswersNull() {
        val channel = channel()
        val closed = channel.call("scan")
        screen.cancelled!!()
        assertTrue(closed.answered)
        assertNull(closed.value)
        assertNull(closed.errorCode)
        // An empty code is no code.
        val empty = channel.call("scan")
        screen.success!!("")
        assertNull(empty.value)
    }

    @Test fun aSecondScanWhileOneIsOpenIsBusy() {
        val channel = channel()
        val first = channel.call("scan")
        assertEquals("SCAN_BUSY", channel.call("scan").errorCode)
        screen.success!!("one")
        assertEquals("one", first.value)
        // The slot opens again after the answer.
        val next = channel.call("scan")
        screen.success!!("two")
        assertEquals("two", next.value)
    }

    @Test fun failuresAreMappedToTheirCodes() {
        fun failWith(error: Exception): String? {
            val answer = channel().call("scan")
            screen.failure!!(error)
            return answer.errorCode
        }
        assertEquals("SCAN_DOWNLOADING", failWith(MlKitException("downloading", 200)))
        assertEquals("SCAN_UNSUPPORTED", failWith(MlKitException("unsupported", 207)))
        assertEquals("SCAN", failWith(MlKitException("other", 13)))
        assertEquals("SCAN", failWith(IllegalStateException("anything")))
    }

    @Test fun aStuckPreparationTimesOut() {
        // The module never reports: the timer ends the scan.
        val modules = object : BarcodeScanModuleInstaller {
            override fun areModulesAvailable(onResult: (Boolean) -> Unit, onFailure: (Exception) -> Unit) {}

            override fun install(onInstalled: () -> Unit, onCancelled: () -> Unit, onFailure: (Exception) -> Unit) =
                BarcodeScanCancellation {}
        }
        val channel = ScannerChannel(newFlow = { done -> BarcodeScanFlow(modules, screen, done) }, timer = timer, reply = direct)
        val answer = channel.call("scan")
        timer.action!!()
        assertEquals("SCAN_TIMEOUT", answer.errorCode)
    }

    @Test fun theTimeoutDoesNotEndAnOpenScanner() {
        val channel = channel()
        val answer = channel.call("scan")
        timer.action!!()
        assertFalse(answer.answered)
        screen.success!!("late but fine")
        assertEquals("late but fine", answer.value)
    }

    @Test fun preparationCanBeCancelledButAnOpenScannerCannot() {
        val waiting = object : BarcodeScanModuleInstaller {
            override fun areModulesAvailable(onResult: (Boolean) -> Unit, onFailure: (Exception) -> Unit) {}

            override fun install(onInstalled: () -> Unit, onCancelled: () -> Unit, onFailure: (Exception) -> Unit) =
                BarcodeScanCancellation {}
        }
        val preparing = ScannerChannel(newFlow = { done -> BarcodeScanFlow(waiting, screen, done) }, timer = timer, reply = direct)
        val answer = preparing.call("scan")
        assertEquals(true, preparing.call("cancelPreparation").value)
        assertTrue(answer.answered)
        assertNull(answer.value)

        val open = channel()
        val scanning = open.call("scan")
        assertEquals(false, open.call("cancelPreparation").value)
        assertFalse(scanning.answered)
    }

    @Test fun aModuleInstallFailureKeepsOnlyItsNumericCode() {
        val answer = scanAnswer(BarcodeScanOutcome.Failure(BarcodeScanModuleInstallException(7)))
        assertEquals(ScanAnswer.Failure("SCAN", mapOf("moduleInstallErrorCode" to 7)), answer)
        assertEquals(
            ScanAnswer.Failure("SCAN_TIMEOUT"),
            scanAnswer(BarcodeScanOutcome.Failure(BarcodeScanPreparationTimeoutException())),
        )
    }

    @Test fun answersGoThroughTheReplyThread() {
        val posted = mutableListOf<Runnable>()
        val channel = ScannerChannel(
            newFlow = { done -> BarcodeScanFlow(Modules(), screen, done) },
            timer = timer,
            reply = { posted += it },
        )
        val answer = channel.call("scan")
        screen.success!!("text")
        assertFalse(answer.answered)
        posted.single().run()
        assertEquals("text", answer.value)
    }

    @Test fun detachingEndsAnOpenScanAsClosed() {
        val channel = channel()
        val answer = channel.call("scan")
        channel.detach()
        assertTrue(answer.answered)
        assertNull(answer.value)
        assertTrue(channel.call("unknown").notImplemented)
    }
}
