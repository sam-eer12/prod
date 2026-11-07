PadLink Android 0.1.3 adds an experimental Xbox One S Bluetooth controller profile.

- Matches the original compact Xbox One S Bluetooth Classic report descriptor, button order, unsigned 16-bit sticks, independent 10-bit analog triggers and eight-way D-pad.
- Adds a visible Home control, separate Guide and battery input reports, and Xbox rumble output handling through both Bluetooth output paths.
- Adds a Game vibration setting. Xbox's four motor strengths are combined onto the phone's vibration motor; touch feedback remains separately configurable.
- Keeps the generic Bluetooth gamepad as the default and preserves layout editing, foreground play and reconnection behavior.

To try the new profile:

1. Install the signed APK on an Android 9+ phone with Bluetooth HID Device support.
2. Close the controller or stop Bluetooth, then select **Settings → Bluetooth controller profile → Xbox One S Bluetooth**.
3. Forget the phone on your laptop and forget the laptop on your phone. Hosts cache the controller descriptor, so a fresh pairing is required when switching either way.
4. Start Bluetooth in PadLink, make the phone discoverable and pair again. Keep PadLink open, and restart the game after re-pairing.

Android still supplies the Bluetooth vendor/product IDs. This profile cannot establish a complete Xbox device identity on a stock phone, and native Roblox compatibility on macOS remains unverified. Browser gamepad detection alone does not prove native game support. Phone vibration and radio behavior still require physical-device testing.

This Android-only release includes the signed APK and its SHA-256 checksum. It uses the same signing certificate as the previous Android release and can upgrade it in place. Desktop CLI assets are not republished.
