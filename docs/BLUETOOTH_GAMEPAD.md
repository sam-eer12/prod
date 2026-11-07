# Direct Bluetooth gamepad

Bluetooth mode connects the Android phone directly to a laptop's native
Bluetooth HID stack. It needs no PadLink CLI, background daemon, Wi-Fi network,
or Apple virtual-HID entitlement. This mode uses the operating systems' Bluetooth
pairing flow rather than PadLink's Wi-Fi token flow.

## Connect

1. Install the signed Android APK from GitHub Releases. Android 9/API 28 or later
   is required, with a working Bluetooth HID Device profile.
2. Open PadLink and tap **Start Bluetooth**. On Android 12+, allow nearby-device
   access. Turn on Bluetooth if prompted.
3. Tap **Make discoverable** and pair the phone in the laptop's Bluetooth settings
   during the 120-second discovery window. Keep PadLink open. If the laptop is
   already paired, refresh the paired-device list and tap **Connect to** its name.
4. The controller opens when the HID connection succeeds. Use it with a game or
   a gamepad tester on the laptop.
5. Close the controller or tap **Stop Bluetooth** to release input and disconnect.
   Pressing Home pauses Bluetooth and clears held controls. Reopening restores
   the current screen and re-registers/reconnects to the same bonded laptop.
   An explicit Close or Stop ends the session and disables automatic reconnect.

Only one laptop receives input at a time. Starting Wi-Fi listening stops Bluetooth
mode. Local **Try controller** preview sends no input unless a Bluetooth session
is already connected. Settings, the layout editor, and cancelled/focus-lost
touches produce neutral input. Returning from settings starts with cleared
touch state. Navigation and an unsaved editor draft survive backgrounding and
Android activity recreation; held controls are deliberately not restored.

## Layout and touch vibration

Open **Settings → Edit layout**. Drag a gameplay control to move it, or use
**Adjust control** to select a control, change its size, and move it in 4 dp
steps. Joystick caps and travel resize with their bases. **Save layout** applies
the draft locally; **Cancel** discards it. **Reset** restores defaults in the
draft and takes effect after Save. Settings and Close stay fixed and reachable.
Saving requires separate, in-bounds touch circles of at least 48 dp. A malformed
stored profile falls back to defaults. If a saved layout cannot fit a different
window, gameplay uses defaults and shows a notice to adjust it.

Touch feedback uses the Android 12+ default vibrator through VibratorManager,
with direct one-shot effects and default amplitude on motors without amplitude
control. Stick movement uses 16 ms pulses, increasing from 75 to 140/255;
buttons use 35 ms at 170/255. Stationary sticks and small jitter stay silent,
and both sticks share a 50 ms pulse interval. Settings includes **Test vibration**
and reports unavailable motors or disabled Android touch vibration. The app
switch and Android touch-feedback setting are respected. The Vivo V27 Pro on
Android 15 is the user's physical test target; motor feel and vendor setting
behavior still require that test.

## Controller mapping

| Control | HID report |
| :--- | :--- |
| A, B, X, Y | Buttons 1–4 |
| LB, RB | Buttons 5–6 |
| View/Back, Menu/Start | Buttons 7–8 |
| Guide/Home | Button 9, reserved for a future visible control |
| L3, R3 | Buttons 10–11 |
| D-pad | Hat switch, directions 0–7; 8 is neutral |
| Left stick | Signed 16-bit X/Y |
| Right stick | Signed 16-bit Rx/Ry |
| LT, RT | Independent unsigned 8-bit Z/Rz, 0–255 |
| Settings, Close | Local app actions; no HID button |

X grows right and Y grows down. Opposite D-pad directions cancel. Non-finite
values become neutral; analog values are clamped. Each touch transition sends a
report immediately, with a periodic current-state report while connected.
The descriptor has a single Generic Desktop/Game Pad application collection,
13 bytes of input, and no keyboard, mouse, relative pointer, output, or feature
reports. It does not advertise game-controlled rumble.

## Support and testing

Bluetooth profile availability varies by Android vendor. A failed profile bind,
registration, missing permission, or connection timeout produces an explicit
error and leaves input inactive. Android can unregister the HID app when it is
backgrounded, so this release supports foreground play only.

macOS, Windows, and Linux normally provide Bluetooth HID support. A correct HID
descriptor does not prove that every OS/game layer accepts a controller. In
particular, a generic Bluetooth gamepad is not an XInput device; XInput-only games
may require a different mode or Steam Input configuration. The descriptor and
Android behavior are checked automatically; actual radio connection, OS gamepad
recognition, all control mappings, and gameplay require testing on a physical
phone and laptop. No physical compatibility row is claimed until that test passes.

When testing, verify that the desktop shows a game controller, that no keyboard
or mouse device appears for PadLink, and that both sticks, triggers, eight D-pad
directions, face/shoulder buttons, Back/Start, and L3/R3 work independently. Also
check a short tap, cancelled touch, settings, close, backgrounding, Bluetooth
loss, and reconnection. Direct Bluetooth uses OS connection-loss handling; the
Wi-Fi protocol's desktop watchdog and session-resume rules do not apply here.
