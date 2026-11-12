PadLink Android 0.1.4 improves Bluetooth HID stability and cleans up layout editing.

- Fixes Generic Bluetooth gamepad HID report descriptor and D-pad null-state handling for compatibility with Windows, macOS, and Linux.
- Resolves Bluetooth HID connection drops by handling L2CAP buffer congestion gracefully and supporting in-progress bonding.
- Prevents accidental Bluetooth HID disconnection when pulling down the Android notification shade or quick settings.
- Removes redundant directional nudge buttons from the layout editor adjustment dialog in favor of direct touch manipulation.
- Includes experimental Xbox One S Bluetooth controller profile support with rumble and battery reporting.

To use the gamepad:

1. Install the signed APK on an Android 9+ phone with Bluetooth HID Device support.
2. Tap **Start Bluetooth**, make the phone discoverable, and pair it in your laptop's Bluetooth settings.
3. If upgrading from an earlier version, forget the old pairing on both devices first so the host reads the updated HID descriptor.
4. Keep PadLink open; the controller opens automatically when connected.

This Android-only release includes the signed APK and its SHA-256 checksum. It uses the same release signing key and upgrades prior releases in place.
