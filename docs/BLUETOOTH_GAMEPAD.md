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

### Generic gamepad (default)

| Control | HID report |
| :--- | :--- |
| A, B, X, Y | Buttons 1–4 |
| LB, RB | Buttons 5–6 |
| View/Back, Menu/Start | Buttons 7–8 |
| Guide/Home | Button 9; visible Home control |
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

### Xbox One S Bluetooth (experimental)

Select **Settings → Bluetooth controller profile → Xbox One S Bluetooth** while
Bluetooth is stopped. Close the controller or tap **Stop Bluetooth** first;
the profile selector is locked during registration and an active session.
The selection persists and applies to the next registration, including a
background re-registration. The generic profile remains the default.

After switching in either direction, forget the phone on the laptop **and**
forget the laptop on the phone. Start Bluetooth in PadLink before making it
discoverable, then pair again. Hosts cache the SDP record and HID descriptor;
reconnecting an old pairing is not a reliable profile test. Restart the game
after re-pairing.

This profile implements the original Xbox One S **Bluetooth Classic compact
ten-button/Windows layout**, not Xbox's USB Gaming Input Protocol (GIP), Xbox
Wireless radio protocol, or newer Bluetooth LE firmware layout. It copies the
306-byte descriptor recorded in
[xpadneo's compact-layout descriptor](https://github.com/atar-axis/xpadneo/blob/master/docs/descriptors/xb1s_windows.md),
omitting that document's trailing non-HID NUL byte. The local reference fixture
is `android/app/src/test/resources/xbox_one_s_windows.hex`. Its main packet
matches SDL's `HIDAPI_DriverXboxOneBluetooth_HandleButtons16` parsing in
[SDL_hidapi_xboxone.c](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_xboxone.c).
The reference hex declares a stick maximum of **65535**, despite the reference
document's decoded comments saying 65534.

The SDP name and description are `Xbox Wireless Controller`; the provider
string is `Microsoft`, with Android's gamepad subclass. These strings do not
change the separate Bluetooth Device ID record or the phone's system Bluetooth
name. The laptop's pairing UI may still display the phone's name.

| Report | Data bytes, excluding report ID | Contents |
| :--- | :--- | :--- |
| Input 1 | 15 | Four unsigned 16-bit stick axes; two 10-bit triggers in 16-bit slots; hat; ten button bits |
| Input 2 | 1 | Guide/Home bit and seven zero padding bits |
| Output 3 | 8 | Motor enable mask; four strengths; duration; start delay; loop count |
| Input 4 | 1 | Xbox battery level and power-source flags |

Main input offsets are: left X/Y at 0/2, right Rx/Ry at 4/6, LT Z at 8,
RT Rz at 10, hat at 12, and little-endian buttons at 13–14. Sticks run from
0–65535 with neutral 32768; triggers run from 0–1023 with neutral 0. Trigger
padding remains zero. The hat uses 1–8 clockwise from Up and 0 for neutral.
Buttons are A/B/X/Y/LB/RB/View/Menu/L3/R3 in bits 0–9. Internal Guide bit 8
is removed from this bitmap and sent separately, with explicit press/release
transitions. Android receives the report ID separately from the data; it adds
the ID on the wire. A main input packet is therefore 16 bytes at a host that
includes the report ID in its HID read buffer.

All three input reports are sent on connection. Held controls are cleared on
disconnect/reconnect, backgrounding and release. GET_REPORT supports each
declared input report and the last valid rumble output; invalid IDs, lengths and
unsupported report types receive HID errors. Rumble accepts both control-channel
SET_REPORT (with a success handshake) and interrupt-channel output data. Its
four Xbox motor strengths are combined onto the phone's single vibration motor;
this cannot reproduce four independently placed Xbox actuators. Timing uses
10 ms units, with a finite waveform for the requested repeats. A zero-strength
or zero-duration command stops vibration, as do disconnection and backgrounding.
**Game vibration** can be disabled independently of touch feedback and respects
the phone's vibration settings. Touch feedback and rumble share the phone's
actuator, so local pulses can interrupt a rumble waveform.

Battery reports sample the phone on connection, on a battery GET_REPORT, and
every 30 seconds while connected. They encode the four Xbox coarse levels and
charging/power source, not a raw percentage. No keyboard or mouse collection or
feature report is added.

### Identity and native macOS games

Android's public
[BluetoothHidDeviceAppSdpSettings API](https://developer.android.com/reference/android/bluetooth/BluetoothHidDeviceAppSdpSettings)
accepts only name, description, provider, subclass and report descriptor. It has
no vendor ID, product ID, vendor-ID source, firmware version, Bluetooth address
or arbitrary SDP-attribute field. Those come from the phone's Bluetooth stack.
This profile consequently **does not** set Microsoft's `045e` vendor ID or an
Xbox One S product ID such as `02fd`, and does not establish Windows XInput or
native Roblox compatibility. OEM-provided IDs can vary.

Browser Gamepad API detection demonstrates HID input, not native game support.
If a Mac driver or game uses known device IDs to select a controller, matching
these reports will not bypass that requirement. Complete identity emulation
would require a modified/rooted Bluetooth stack or a different HID device/host
bridge that can supply its own identity. Native Roblox acceptance remains a
physical test; no successful result is claimed for this profile.

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

For the Xbox profile also check Home press/release, independent analog triggers,
host rumble and its stop command, disabling Game vibration, battery status, and
both directions of a profile change followed by a fresh pairing. Test native
Roblox separately from the browser tester. Unit tests verify the exact reference
descriptor, all declared packet lengths/IDs, button and hat mappings, analog
ranges/padding, Guide transitions, battery flags and rumble parsing/timing.
