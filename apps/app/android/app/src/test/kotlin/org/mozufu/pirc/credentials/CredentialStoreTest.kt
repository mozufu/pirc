package org.mozufu.pirc.credentials

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStoreException
import java.util.concurrent.Executor
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Robolectric has no AndroidKeyStore provider, so these tests give the store a software
 * AES key; the Keystore key itself is checked only on a device.
 */
@RunWith(RobolectricTestRunner::class)
class CredentialStoreTest {
    private val prefs = RuntimeEnvironment.getApplication()
        .getSharedPreferences("credentials", Context.MODE_PRIVATE)
    private var key = newKey()
    private var keystoreFails = false
    private val store = KeystoreCredentialStore(prefs) {
        if (keystoreFails) throw KeyStoreException("busy")
        key
    }

    private fun newKey(): SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

    @Test fun nothingSavedReadsNull() {
        assertNull(store.read())
    }

    @Test fun savesReadsAndDeletes() {
        store.save("pirc_dev_first")
        assertEquals("pirc_dev_first", store.read())
        store.save("pirc_dev_second")
        assertEquals("pirc_dev_second", store.read())
        store.delete()
        assertNull(store.read())
        assertFalse(prefs.contains("sealed"))
    }

    @Test fun theTokenIsNotStoredInPlainText() {
        store.save("pirc_dev_secret")
        assertTrue(prefs.all.values.none { "pirc_dev_secret" in it.toString() })
    }

    @Test fun theIvAndTheCiphertextAreOneValue() {
        store.save("pirc_dev_first")
        // Another store of the same process (the background client) saves meanwhile.
        KeystoreCredentialStore(prefs) { key }.save("pirc_dev_second")
        assertEquals(setOf("sealed"), prefs.all.keys)
        assertEquals("pirc_dev_second", store.read())
    }

    @Test fun aKeystoreFailureForAWhileKeepsTheToken() {
        store.save("pirc_dev_first")
        keystoreFails = true
        assertThrows(KeyStoreException::class.java) { store.read() }
        keystoreFails = false
        assertEquals("pirc_dev_first", store.read())
    }

    @Test fun aDamagedValueIsDeleted() {
        prefs.edit().putString("sealed", "AA==").commit()
        assertNull(store.read())
        assertFalse(prefs.contains("sealed"))
    }

    @Test fun aLostKeyDeletesTheTokenSoTheUserPairsAgain() {
        store.save("pirc_dev_first")
        key = newKey()
        assertNull(store.read())
        assertFalse(prefs.contains("sealed"))
    }

    @Test fun theChannelReadsSavesAndDeletes() {
        val direct = Executor { it.run() }
        val channel = CredentialsChannel(store, direct, direct)
        assertEquals("credentials", channel.name)
        fun call(method: String, args: Map<String, Any?>? = null): Recorded =
            Recorded().also { channel.onMethodCall(MethodCall(method, args), it) }

        assertEquals(Recorded(success = true), call("read"))
        assertEquals(Recorded(success = true), call("save", mapOf("token" to "pirc_dev_channel")))
        assertEquals(Recorded(success = true, value = "pirc_dev_channel"), call("read"))
        assertEquals(Recorded(success = true), call("delete"))
        assertNull(store.read())
        assertEquals("INVALID", call("save", mapOf("token" to "")).error)
        assertTrue(call("other").notImplemented)
    }

    private data class Recorded(
        var success: Boolean = false,
        var value: Any? = null,
        var error: String? = null,
        var notImplemented: Boolean = false,
    ) : MethodChannel.Result {
        override fun success(result: Any?) {
            success = true
            value = result
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            error = errorCode
        }

        override fun notImplemented() {
            notImplemented = true
        }
    }
}
