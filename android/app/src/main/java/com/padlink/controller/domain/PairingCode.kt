package com.padlink.controller.domain

/**
 * Shape rules for the six-character pairing code.
 *
 * This object does not generate or authenticate codes. A reviewed PAKE
 * implementation owns that behavior; keeping the alphabet in one place lets
 * the UI and tests agree on what the user is expected to type.
 */
object PairingCode {
    const val LENGTH: Int = 6
    const val ALPHABET: String = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

    fun isWellFormed(value: String): Boolean =
        value.length == LENGTH && value.all { character -> character in ALPHABET }
}
