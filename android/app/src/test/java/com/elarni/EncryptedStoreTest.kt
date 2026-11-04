package com.elarni

import org.junit.Assert.*
import org.junit.Test
import javax.crypto.KeyGenerator

// The Android Keystore key and AtomicFile need a device; this covers the file format they protect.
class EncryptedStoreTest {
    private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private val aad = "com.elarni.catalog.v1".toByteArray()
    private val plain = """{"journalVersion":1}""".toByteArray()

    @Test fun roundTripKeepsTheExistingLayout() {
        val sealed = EncryptedStore.seal(plain, aad, key)
        // Installed apps hold files in this layout; a change would make every catalog unreadable.
        assertEquals("RVAD1", String(sealed, 0, 5, Charsets.US_ASCII))
        assertEquals(5 + 12 + plain.size + 16, sealed.size)
        assertArrayEquals(plain, EncryptedStore.unseal(sealed, aad) { key })
    }

    @Test fun everySaveUsesAFreshNonce() {
        val first = EncryptedStore.seal(plain, aad, key); val second = EncryptedStore.seal(plain, aad, key)
        assertFalse("GCM must never reuse an IV under one key", first.copyOfRange(5, 17).contentEquals(second.copyOfRange(5, 17)))
    }

    @Test fun tamperingOrAnotherStoresFileDoesNotOpen() {
        val sealed = EncryptedStore.seal(plain, aad, key)
        for (index in listOf(5, 17, sealed.size - 1)) {
            val damaged = sealed.copyOf().also { it[index] = (it[index].toInt() xor 1).toByte() }
            assertTrue("byte $index", runCatching { EncryptedStore.unseal(damaged, aad) { key } }.isFailure)
        }
        assertTrue("A file moved from another store", runCatching { EncryptedStore.unseal(sealed, "com.elarni.other.v1".toByteArray()) { key } }.isFailure)
        val otherKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        assertTrue(runCatching { EncryptedStore.unseal(sealed, aad) { otherKey } }.isFailure)
    }

    @Test fun aDamagedHeaderReadsAsCorruptWithoutAskingForTheKey() {
        val sealed = EncryptedStore.seal(plain, aad, key)
        for (bytes in listOf(sealed.copyOf(32), byteArrayOf(), "RVAD2".toByteArray() + sealed.copyOfRange(5, sealed.size))) {
            val error = runCatching { EncryptedStore.unseal(bytes, aad) { throw AppFailure("storage_locked") } }.exceptionOrNull()
            assertEquals("storage_corrupt", (error as? AppFailure)?.code)
        }
    }
}
