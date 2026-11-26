package org.mozufu.pirc.credentials

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.security.UnrecoverableKeyException
import java.util.Base64
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The device token. Read and save touch the Keystore, which can take 100 ms or more
 * on first use: call them off the main thread. [read] throws when the Keystore fails
 * for a while; the token is then kept.
 */
interface CredentialStore {
    fun read(): String?
    fun save(token: String)
    fun delete()
}

/**
 * Keeps the device token encrypted with a non-exportable AES-GCM key in the Android
 * Keystore (alias `pirc-device-token`). The app opts out of backups, so the ciphertext
 * never leaves the phone either. [key] returns the key, making it on first use.
 *
 * The IV and the ciphertext are kept as one value, so a read never pairs the IV of one
 * save with the ciphertext of another. Writes lock [prefs], which Android shares between
 * all stores of one process.
 */
class KeystoreCredentialStore(
    private val prefs: SharedPreferences,
    private val key: () -> SecretKey,
) : CredentialStore {
    override fun read(): String? {
        val stored = prefs.getString(SEALED, null) ?: return null
        return try {
            // One byte of IV length, the IV, then the ciphertext with its tag.
            val bytes = Base64.getDecoder().decode(stored)
            val ivLength = bytes.firstOrNull()?.toInt() ?: 0
            require(ivLength in 1 until bytes.size) { "Bad IV length" }
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, bytes, 1, ivLength))
            String(cipher.doFinal(bytes, 1 + ivLength, bytes.size - 1 - ivLength), Charsets.UTF_8)
        } catch (error: Exception) {
            if (!error.isPermanent()) throw error
            // A lost or invalidated key, or a damaged value, cannot be recovered: the
            // user pairs again. A token saved meanwhile is kept.
            synchronized(prefs) {
                if (prefs.getString(SEALED, null) == stored) prefs.edit().remove(SEALED).commit()
            }
            null
        }
    }

    override fun save(token: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.doFinal(token.toByteArray(Charsets.UTF_8))
        val iv = cipher.iv
        val bytes = byteArrayOf(iv.size.toByte()) + iv + sealed
        val saved = synchronized(prefs) {
            prefs.edit().putString(SEALED, Base64.getEncoder().encodeToString(bytes)).commit()
        }
        check(saved) { "The token could not be saved" }
    }

    override fun delete() {
        synchronized(prefs) { prefs.edit().remove(SEALED).commit() }
    }

    companion object {
        const val ALIAS = "pirc-device-token"
        private const val PREFS = "credentials"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val TAG_BITS = 128
        private const val SEALED = "sealed"

        /** Failures that reading again cannot fix. */
        private fun Exception.isPermanent() = this is AEADBadTagException ||
            this is KeyPermanentlyInvalidatedException ||
            this is UnrecoverableKeyException ||
            this is IllegalArgumentException

        fun create(context: Context) = KeystoreCredentialStore(
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE),
            ::keystoreKey,
        )

        private fun keystoreKey(): SecretKey {
            val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
            (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
            generator.init(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build(),
            )
            return generator.generateKey()
        }
    }
}
