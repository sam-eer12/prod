PadLink Android adds direct Bluetooth gamepad mode. No PadLink desktop CLI, daemon, or Wi-Fi connection is needed in this mode.

1. Install the signed APK on an Android 9+ phone.
2. Tap **Start Bluetooth** and allow nearby-device access when requested.
3. Tap **Make discoverable**, then pair the phone in the laptop's Bluetooth settings. Keep PadLink open. If already paired, select the laptop under **Connect to**.
4. Once connected, use the landscape controller. Pressing Home pauses gameplay; reopening restores the screen and reconnects to the same laptop. Close or Stop Bluetooth ends the session.

The Bluetooth HID descriptor exposes one gamepad with A/B/X/Y, LB/RB, Back/Start, L3/R3, eight-way D-pad, two sticks, and independent analog triggers; Guide is reserved in the report. It does not expose a keyboard or mouse. Controls and local haptics clear on cancellation, focus loss, and disconnect; settings and layout editing keep the gamepad neutral.

**Settings → Edit layout** lets you drag, resize, save, cancel, and reset gameplay controls. Accessible adjustment buttons move controls in small steps. Touch targets remain at least 48 dp; overlapping or offscreen layouts cannot be saved. Settings and Close remain fixed. Unsaved edits and the current screen survive backgrounding and activity recreation.

Touch vibration now uses direct effects on Android 15, including motors without amplitude control, with clearer button and joystick pulses. **Test vibration** in Settings helps verify it on your phone and reports disabled Android touch vibration. Physical vibration feel, including on the Vivo V27 Pro, needs phone testing.

The phone must support Android's Bluetooth HID Device profile. The app detects profile/registration failures and shows a clear error. macOS, Windows, and Linux use their native Bluetooth HID support; controller recognition and game compatibility still need physical-device testing. Games requiring XInput may not accept a generic Bluetooth HID gamepad. Game rumble is not advertised.

Wi-Fi CLI gameplay remains deferred; its existing pairing check and desktop release assets remain available separately. This Android-only release does not replace the CLI's latest-release installation channel.

The APK uses the same signing certificate as the previous Android release. A SHA-256 checksum is included.
