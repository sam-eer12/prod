package com.padlink.controller.domain

/**
 * High-level state of the phone side of a PadLink session.
 *
 * The scaffold only renders [NOT_CONNECTED]. The remaining values describe the
 * states the networking milestone will implement.
 */
enum class ConnectionState {
    NOT_CONNECTED,
    LISTENING,
    PAIRING,
    CONNECTED,
    ERROR,
}
