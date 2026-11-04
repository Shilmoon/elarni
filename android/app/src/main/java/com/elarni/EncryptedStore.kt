package com.elarni

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** One private, atomic, authenticated catalog. Key loss never creates a blank replacement. */
class EncryptedStore(private val context: Context, name: String = "catalog") {
    private val file = AtomicFile(File(context.noBackupFilesDir, "$name.v1.enc"))
    private val alias = "${context.packageName}.$name.v1"
    private val aad = alias.toByteArray(Charsets.UTF_8)
    private fun exists() = file.baseFile.exists() || File(file.baseFile.path + ".bak").exists()
    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        if (!create) throw AppFailure("storage_locked")
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    @Synchronized fun load(): JSONObject? {
        if (!exists()) return null
        try {
            val bytes = file.openRead().use { input ->
                input.readBounded(16 * 1024 * 1024)
            }
            return JSONObject(String(unseal(bytes, aad) { key(false) }, Charsets.UTF_8))
        } catch (error: AppFailure) { throw error }
        catch (_: Exception) { throw AppFailure("storage_corrupt") }
    }
    @Synchronized fun save(value: JSONObject) {
        val plain = value.toString().toByteArray(Charsets.UTF_8)
        if (plain.size > 12 * 1024 * 1024) throw AppFailure("input_too_large")
        try {
            val sealed = seal(plain, aad, key(!exists()))
            val output = file.startWrite()
            try {
                output.write(sealed)
                file.finishWrite(output)
            } catch (error: Exception) { file.failWrite(output); throw error }
        } catch (_: Exception) { throw AppFailure("storage_unavailable") }
    }
    companion object {
        /** "RVAD1", the cipher's 12-byte IV, then the AES-GCM ciphertext and tag; [aad] binds it to one store. */
        fun seal(plain: ByteArray, aad: ByteArray, key: SecretKey): ByteArray {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key)
            cipher.updateAAD(aad)
            val encrypted = cipher.doFinal(plain)
            return "RVAD1".toByteArray(Charsets.US_ASCII) + cipher.iv + encrypted
        }
        /** Checks the header before asking for [key], so a damaged file reads as corrupt, not locked. */
        fun unseal(bytes: ByteArray, aad: ByteArray, key: () -> SecretKey): ByteArray {
            if (bytes.size < 33 || String(bytes.copyOfRange(0, 5), Charsets.US_ASCII) != "RVAD1") throw AppFailure("storage_corrupt")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(5, 17)))
            cipher.updateAAD(aad)
            return cipher.doFinal(bytes.copyOfRange(17, bytes.size))
        }
    }
}
