package com.padlink.controller.domain

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingCodeTest {

    @Test
    fun `alphabet has 32 unique symbols`() {
        assertTrue(PairingCode.ALPHABET.length == 32)
        assertTrue(PairingCode.ALPHABET.toSet().size == PairingCode.ALPHABET.length)
    }

    @Test
    fun `accepts a well formed code`() {
        assertTrue(PairingCode.isWellFormed("7K4M2Q"))
    }

    @Test
    fun `rejects codes with the wrong length`() {
        assertFalse(PairingCode.isWellFormed("7K4M2"))
        assertFalse(PairingCode.isWellFormed("7K4M2QX"))
    }

    @Test
    fun `rejects lowercase and ambiguous characters`() {
        assertFalse(PairingCode.isWellFormed("7k4m2q"))
        assertFalse(PairingCode.isWellFormed("7K4M2I"))
        assertFalse(PairingCode.isWellFormed("7K4M20"))
    }
}
