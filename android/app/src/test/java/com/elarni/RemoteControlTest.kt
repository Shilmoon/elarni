package com.elarni

import org.junit.Assert.*
import org.junit.Test

class RemoteControlTest {
    @Test fun onlyTheStoredKeyIsAuthorized() {
        val key = RemoteControl.newKey()
        assertTrue(RemoteControl.authorized(key, key))
        assertTrue("A copy, not the same object", RemoteControl.authorized(key, String(key.toCharArray())))
        assertFalse(RemoteControl.authorized(key, RemoteControl.newKey()))
        assertFalse("A prefix", RemoteControl.authorized(key, key.dropLast(1)))
        assertFalse("A longer key", RemoteControl.authorized(key, key + "A"))
        assertFalse("Case matters", RemoteControl.authorized("Ab-Cd_09", "ab-cd_09"))
        assertFalse("A missing extra", RemoteControl.authorized(key, null))
        assertFalse("An empty extra", RemoteControl.authorized(key, ""))
    }

    @Test fun noStoredKeyAdmitsNothing() {
        for (given in listOf(null, "", "anything")) assertFalse("$given", RemoteControl.authorized("", given))
    }

    @Test fun keysAreRandom128BitUrlSafeText() {
        val keys = List(64) { RemoteControl.newKey() }
        assertEquals("Each key is new", keys.size, keys.toSet().size)
        for (key in keys) {
            assertTrue(key, Regex("[A-Za-z0-9_-]{22}").matches(key))
            assertEquals(16, java.util.Base64.getUrlDecoder().decode(key).size)
        }
    }
}
