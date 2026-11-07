# PadLink

PadLink turns an Android phone into a low-latency gamepad for a desktop on the
same local network. The shared protocol and pairing core now powers a real
Android listening/consent/token flow and the desktop `padlink pair` check.
Both use the same Rust SPAKE2 handshake, bounded TCP adapters, traffic keys,
replay protection, and memory-only session lifetime. Authenticated endpoint
resumption rotates keys and epochs and is exposed through Rust and Android JNI.
Android also has a local controller surface with multi-touch controls and haptic
feedback. The desktop now has per-user daemon/IPC management, installers and
signed updates. Discovery, input transport and native gamepad backends remain
future work. **Pairing verification does not open a desktop gameplay session.**

The product requirements and engineering plan live in
[PRD.md](PRD.md) and [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md). The
original product prompt is preserved at the top of the PRD.

## Install the CLI

Install the latest prebuilt CLI with the command for your desktop. No Rust
toolchain is required.

### macOS and Linux

```sh
curl -fsSL --proto '=https' --proto-redir '=https' https://github.com/sam-eer12/prod/releases/latest/download/install.sh -o padlink-install.sh && sh padlink-install.sh --add-to-path
```

### Windows (PowerShell 5.1+)

```powershell
curl.exe -fsSL --proto '=https' --proto-redir '=https' https://github.com/sam-eer12/prod/releases/latest/download/install.ps1 -o padlink-install.ps1
if ($LASTEXITCODE -eq 0) { & .\padlink-install.ps1 -AddToPath }
```

Open a new terminal after installation, then run:

```sh
padlink
padlink daemon start
padlink update
```

The commands download the complete installer before running it. The installers
verify the release signature and checksums and add the CLI to your user PATH.
Run the macOS/Linux installer without sudo. Installation starts no daemon automatically.
`padlink update --check` checks without installing; `padlink autostart enable`
opts into login startup; `padlink uninstall` removes the CLI while retaining user state.

Prebuilt targets: macOS 13+ Intel/Apple Silicon, Linux 5.4+ x64/ARM64 and
Windows 10+ x64. macOS CLI builds need no paid Apple Developer identity.
Windows PowerShell instructions, release trust, PATH setup and rollback are in
[docs/CLI_DISTRIBUTION.md](docs/CLI_DISTRIBUTION.md).

## What is in this setup

| Area | Status |
| :--- | :--- |
| Android app (native Kotlin) | Wi-Fi pairing plus a local landscape View/Canvas controller with clamped recessed joysticks, darkened button press states, analog triggers, eight-way D-pad, and optional touch haptics |
| Android tests | JVM input/haptic rules, multi-touch/render/navigation checks, Compose launch/consent/backgrounding, real JNI socket pairing/retry/encrypted exchange and authenticated resume |
| Desktop CLI | Phone pairing verification, private daemon lifecycle/IPC, optional login startup, curl/PowerShell installation, verified updates and rollback |
| Shared protocol crate | Exact codecs, RFC-vector-tested SPAKE2, bounded TCP adapters, admission/consent, AEAD/replay, fixed edge storage, clock bounds, watchdog, authenticated resume and session expiry |
| Android native crate | Checked JNI handles; the same Rust core packaged for arm64-v8a, armeabi-v7a, x86 and x86_64 with 16 KiB ELF alignment |
| Documentation | PRD, implementation plan, controller layout reference, protocol specification |

Android Studio is the build/debug IDE. The installed app runs on Android's ART
runtime; the desktop tool is a separate native Rust binary.

## Repository layout

```text
.
├── android/                        # Standalone Gradle project (open this in Android Studio)
│   ├── app/
│   │   ├── build.gradle.kts
│   │   └── src/
│   │       ├── main/
│   │       │   ├── AndroidManifest.xml
│   │       │   ├── java/com/padlink/controller/
│   │       │   │   ├── PadLinkApplication.kt
│   │       │   │   ├── MainActivity.kt
│   │       │   │   ├── domain/       # Pure Kotlin models and rules
│   │       │   │   └── ui/           # Compose app shell, screens, theme, navigation
│   │       │   └── res/              # Strings, theme, adaptive icon
│   │       ├── test/                 # JVM unit tests
│   │       └── androidTest/          # Instrumented Compose test
│   ├── gradle/
│   │   ├── libs.versions.toml        # Single source of dependency/plugin versions
│   │   └── wrapper/
│   ├── build.gradle.kts
│   ├── settings.gradle.kts
│   └── gradlew
├── desktop/                        # Rust CLI crate (`padlink` binary)
│   ├── Cargo.toml
│   └── src/main.rs
├── android-native/                 # Checked JNI boundary and four-ABI NDK build
├── protocol/                       # Shared protocol crate + draft specification
│   ├── Cargo.toml
│   ├── SPEC.md
│   └── src/lib.rs
├── docs/references/                # Supplied controller layout reference
├── Cargo.toml                      # Rust workspace root
├── rust-toolchain.toml
├── PRD.md
└── IMPLEMENTATION_PLAN.md
```

## Toolchain

| Tool | Version used by this baseline |
| :--- | :--- |
| Android Gradle Plugin | 9.4.1 (built-in Kotlin enabled) |
| Gradle | 9.6.0 (wrapper) |
| Kotlin / Compose compiler | 2.2.10 (AGP's built-in Kotlin default) |
| Compose BOM | 2025.09.00 |
| Android compile / target SDK | 37 |
| Android min SDK | 28 |
| Android NDK | 28.2.13676358 |
| Java for Gradle | 17+ |
| Rust | stable, edition 2024 (1.88+) |

Versions are pinned in [android/gradle/libs.versions.toml](android/gradle/libs.versions.toml)
and [Cargo.toml](Cargo.toml). Update them together and re-run the builds.

## Build and run the Android app

1. Install Android SDK Platform 37, Build Tools 36.x and NDK 28.2.13676358 through
   Android Studio's SDK Manager. Install Rust and Python 3, then add native targets:

   ```sh
   rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android
   ```
2. Open the `android/` directory in Android Studio. Do not open the repository
   root; the Gradle project root is `android/`.
3. Let Gradle sync finish, select the `app` run configuration, pick a device or
   emulator running API 28+, and press Run.

Command-line builds:

```sh
cd android
./gradlew :app:assembleDebug
```

The debug APK is written to:

```text
android/app/build/outputs/apk/debug/app-debug.apk
```

Other useful tasks:

```sh
./gradlew :app:testDebugUnitTest     # JVM tests
./gradlew :app:lintDebug             # Android lint
./gradlew :app:assembleRelease       # unsigned release APK
./gradlew :app:compileDebugAndroidTestKotlin
```

Gradle builds and packages all four Rust ABIs automatically. Android Studio
creates `android/local.properties` with your SDK path. That file
is intentionally ignored by Git. Release signing is not configured yet; the
release task produces an unsigned APK.

### Current app behavior

- Home screen: Start listening on Wi-Fi, the actual bound endpoint, an unverified
  desktop name/address with Allow/Deny, then a token with a 60-second countdown.
- Android 17 requests LAN permission before starting. Backgrounding, Stop,
  network loss/address change, or cancellation closes the channel and clears
  token/session material. Listener restart keeps phone-wide request limits.
- Pairing tokens are excluded from screenshots/task previews and saved UI state.
- **Try controller** opens the reference landscape layout locally and stops any
  pairing flow. Both sticks track independently, keep their entire caps inside
  the outer rings, and recenter on release. Face/shoulder/stick-click buttons
  darken while pressed. D-pad slides support diagonals; LT/RT taps fully pull and
  downward drags feather their values, returning to zero on release.
- Joystick movement emits short low-to-medium haptic pulses (50–110/255 amplitude,
  8 ms, at most once per 50 ms across both sticks). Buttons emit medium pulses
  (128/255, 18 ms). Stationary sticks do not vibrate. Devices without amplitude
  control use optional system touch effects; the phone's touch-feedback setting
  and the app's persisted **Touch feedback** switch are respected. Actual feel
  must be checked on a physical phone.
- Controller settings, closing, focus loss, backgrounding, resizing, and cancelled
  touches clear input and stop haptics. Controls use safe-area geometry and at
  least 48 dp touch targets; windows that cannot fit them remain neutral.
- Settings show app information, local controller status, and touch feedback.
  The gear opens settings and returns to a neutral controller. Nothing sends
  gamepad input to the desktop yet; layout editing remains future work.
- Debug builds use the application ID `com.padlink.controller.debug` so they can
  coexist with a release install later.

Controller previews captured from the Android View on an API 36 emulator:
[idle](docs/previews/controller-idle.png),
[dragged stick with A held](docs/previews/controller-dragged.png), and
[B pressed](docs/previews/controller-pressed.png).
Controller UI validation on 2026-11-07: all 13 JVM tests and seven emulator tests
passed; the debug APK and Android lint completed successfully. Physical-device
haptic feel and desktop gameplay are not covered by these checks.

## Build and run the CLI

```sh
cargo build --workspace
cargo run -p padlink-cli -- --help
cargo run -p padlink-cli -- status
cargo run -p padlink-cli -- status --json
cargo run -p padlink-cli -- pair 192.168.1.20:41337 --name "My desktop"
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

`status` reports a stopped or idle daemon, its version, protocol and heap usage.
`daemon start|stop|restart|run`, `autostart enable|disable|status`, `doctor`,
`update` and `uninstall` are implemented. `scan` and `connect` exit with status
`2` and an explicit "not implemented" message. `disconnect` reports no active
gameplay session in this build.
`pair` uses the shared core: start listening in the Android app, copy its actual
endpoint, run this command in a terminal, tap Allow, and enter the six-character
token. Entry is hidden; Escape/Ctrl-C cancels. Up to three attempts share the
original token deadline. The command verifies an encrypted Ping/Pong and clock
bounds, reports success, and closes. It does not retain trust on disk or create
a gamepad. IPv6 endpoints use brackets and numeric link-local scope IDs, for
example `'[fe80::1234%3]:41337'` (the scope is local to the desktop interface).

Protocol-core checks:

```sh
cargo test -p padlink-protocol
cargo clippy -p padlink-protocol --all-targets -- -D warnings
```

`protocol/SPEC.md` documents the exact frame layouts, key schedule, replay and
freshness rules, watchdog timings, and the golden State vector. The core is
**not safe for live input**. Suite 1 pins `pakery-spake2` and `pakery-crypto` at
`0.6.2` using RFC 9382's P-256 suite. Tests match Appendix B's two public shares,
session key, and both HMAC confirmations exactly. This is conformance evidence,
**not an independent security audit**. A release still requires security review,
physical-device/ABI coverage and the remaining P0 failure tests.

The phone issues a token only through the explicit core consent step. The
desktop cannot extract a session until it verifies the phone's confirmation and
an encrypted neutral-ready frame; the phone cannot extract one until the
desktop's confirmation verifies. The Android screen and `padlink pair` invoke
this flow. `protocol/tests/pairing_flow.rs` exercises it in memory;
`protocol/tests/pairing_transport.rs` also runs the handshake and a wrong-code
retry through fragmented real loopback TCP reads/writes.

The shared `PhonePairingHost` admits at most five socket arrivals per rolling
minute globally and per source IP, before parsing. Busy, denied, malformed,
expired, and cancelled requests keep their admission charge. It owns one
pending request, requires an explicit Allow action, and retains the token's
original deadline/attempt budget during same-connection retries. Disconnect
erases the token and requires fresh consent. A phone session remains private
until the authenticated ready frame is fully written.

`FrameReader` and `FrameWriter` each have one fixed 4,096-byte slot. Each poll
performs at most one nonblocking I/O call. Prefix validation precedes body reads;
partial frames and queued writes have absolute three-second progress deadlines
that trickled bytes cannot extend. Caller-driven timers, socket cleanup, OS
buffer limits and future daemon/backend integration still need release validation.
Socket tests require an environment that allows local TCP sockets.

`SessionLease` expires 30 seconds after pairing or the newest validated fresh
input sample. Ping, retry, and resume never extend it. `Resumption` holds one
candidate for at most two seconds, binds both endpoints/challenges and roles,
rotates the root and four traffic keys, and requires a new-key neutral ready
before commit. Rust adapters can transfer ownership with `detach_session`;
Android exposes the same operations through `NativeSession`. Candidate socket
selection, retransmission scheduling and gameplay rearm belong to the future
transport/session owner; automatic network resume is not enabled in this UI.

The desktop allocator accounts Rust heap use with a 4,000,000-byte last-resort
limit; Android native Rust uses 24,000,000 bytes. `status --json` and JNI operation
90 expose heap metrics. These counters exclude OS/native/Java allocations and
thread stacks, and are not aggregate RSS containment. Infallible OOM may abort;
the product's aggregate 75 MB gate remains open.

## Continuous integration

Local validation on 2026-11-06: 156 Rust tests, four Android JVM tests and four
instrumentation tests on an API 36 ARM64 emulator passed. Debug/unsigned release
builds, lint, Clippy and formatting passed. Both APKs contain four native ABIs
with verified 16 KiB ELF/load alignment. A real CLI pseudo-terminal check covered
wrong-code retry, hidden entry, encrypted verification and socket cleanup.

[.github/workflows/ci.yml](.github/workflows/ci.yml) runs on pushes to `main`,
pull requests targeting `main`, and manual runs from GitHub's Actions tab.

- **Rust:** formatting on Linux, plus Clippy and workspace/documentation tests
  on Linux, macOS, and Windows. Dependency resolution uses `Cargo.lock`.
- **Android:** Java 17, Rust Android targets, NDK 28.2.13676358, the Gradle wrapper, Android SDK 37, unit
  tests, lint, debug and unsigned release builds, and instrumentation-test
  compilation.
- **Android emulator:** executes Compose and JNI pairing/resume tests on API 35.
  Physical Wi-Fi, Bluetooth, touch latency, and gamepad backend
  compatibility still require the physical-device tests in the plan.

Installer tooling also receives shell syntax/lint, Python syntax and publisher
key consistency checks. The separate
[CLI release workflow](.github/workflows/release.yml) validates native installers
and signed upgrades on five targets before publishing a tagged production release.

The CI pipeline uploads test/lint reports and the debug APK as seven-day workflow
artifacts. It uses read-only repository permissions, dependency caches, pinned
action revisions, and cancels superseded runs. It does not publish releases or
require release-signing secrets.

## Scope note

The pinned PAKE has no weaker authentication fallback. The app and CLI can
verify pairing now; live gameplay and automatic transport migration are not
enabled. No aggregate memory ceiling or game compatibility is claimed. Local
instrumentation was exercised on an API 36 ARM64 emulator; Android 17 LAN
grant/deny/revoke and every packaged ABI still require runtime device coverage.
The next milestones from the implementation plan are:

1. Bounded discovery and integration with the implemented desktop daemon/IPC.
2. Authenticated UDP path setup/TCP fallback and automatic resume integration,
   Android 17 permission tests, physical-device validation and security review.
3. Connect the local controller View/Canvas to an authenticated input session
   and add the Compose layout editor.

See [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for the full P0/P1 gates and
acceptance criteria.
