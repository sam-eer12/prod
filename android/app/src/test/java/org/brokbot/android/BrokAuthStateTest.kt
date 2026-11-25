package org.brokbot.android

import org.brokbot.android.core.auth.BrokAuthNonce
import org.brokbot.android.core.auth.BrokAuthState
import org.brokbot.android.core.auth.BrokAuthUser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import java.security.MessageDigest

class BrokAuthStateTest {

    @Test
    fun `providerLabel maps google and apple ids`() {
        val google = BrokAuthUser(uid = "u1", email = "a@gmail.com", displayName = "Alex", providerId = "google.com")
        val apple = BrokAuthUser(uid = "u2", email = "a@privaterelay.appleid.com", displayName = "Sam", providerId = "apple.com")
        val other = BrokAuthUser(uid = "u3", email = null, displayName = null, providerId = "custom")

        assertEquals("Google", google.providerLabel)
        assertEquals("Apple", apple.providerLabel)
        assertEquals("custom", other.providerLabel)
    }

    @Test
    fun `auth nonce produces deterministic sha256 hex`() {
        val fixed = BrokAuthNonce.fromRawNonce("brok-test-nonce")
        val expected = MessageDigest.getInstance("SHA-256")
            .digest("brok-test-nonce".toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

        assertEquals(expected, fixed.sha256Hex)
        assertEquals(64, fixed.sha256Hex.length)

        val generated = BrokAuthNonce.generate()
        assertEquals(32, generated.rawNonce.length)
        assertEquals(64, generated.sha256Hex.length)
    }

    @Test
    fun `default auth state is signed out and idle`() {
        val state = BrokAuthState()
        assertNull(state.user)
        assertFalse(state.isLoading)
        assertNull(state.errorMessage)
    }
}
