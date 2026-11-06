# PadLink

PadLink turns an Android phone into a low-latency gamepad for a desktop on the
same local network. This repository is at the **foundation** stage: the Android
app builds and runs, the desktop CLI has its baseline command surface, and the
shared Rust protocol core defines framing, key derivation, replay protection,
lost-edge recovery, freshness, and watchdog behavior. An in-memory six-character
SPAKE2 pairing core is implemented and tested. Discovery, pairing sockets,
Android consent/token UI, controller input, and gamepad backends are not
implemented yet. **The current build is not safe for live input.**

The product requirements and engineering plan live in
[PRD.md](PRD.md) and [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md). The
original product prompt is preserved at the top of the PRD.

## What is in this setup

| Area | Status |
| :--- | :--- |
| Android app (native Kotlin) | Buildable debug/release APKs, Material 3 Compose shell, dark controller-inspired theme, settings and build-info screens |
| Android tests | JVM unit tests for the pairing-code shape rules; one Compose launch test (requires a device/emulator) |
| Desktop CLI | Rust 2024 / Cargo workspace, `clap` command surface, honest `not implemented` exits for unfinished commands |
| Shared protocol crate | State/Edges/control and pre-auth codecs, pinned SPAKE2 pairing state machines with mutual confirmation, HKDF traffic keys, AEAD/replay, bounded edge recovery with distinct reports, conservative freshness, and watchdog; no transport/UI integration yet |
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
| Java for Gradle | 17+ |
| Rust | stable, edition 2024 (1.88+) |

Versions are pinned in [android/gradle/libs.versions.toml](android/gradle/libs.versions.toml)
and [Cargo.toml](Cargo.toml). Update them together and re-run the builds.

## Build and run the Android app

1. Install Android SDK Platform 37 and Build Tools 36.x through Android Studio's
   SDK Manager.
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

Android Studio creates `android/local.properties` with your SDK path. That file
is intentionally ignored by Git. Release signing is not configured yet; the
release task produces an unsigned APK.

### Current app behavior

- Home screen: product scaffold state, connection status card, and settings.
- Settings: app version, build type, package name, and the current controller
  status. Nothing sends gamepad input.
- Debug builds use the application ID `com.padlink.controller.debug` so they can
  coexist with a release install later.

## Build and run the CLI

```sh
cargo build --workspace
cargo run -p padlink-cli -- --help
cargo run -p padlink-cli -- status
cargo run -p padlink-cli -- status --json
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

`status` reports the scaffold state and protocol revision. Commands such as
`scan`, `connect`, `disconnect`, `doctor`, `daemon`, and `autostart` parse their
arguments but exit with status `2` and an explicit "not implemented" message.
They do not print success or fake session data. The CLI does not yet use the
protocol core.

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
Android ABI validation, transport/consent integration, rate limiting, and the P0
failure tests.

The phone issues a token only through the explicit core consent step. The
desktop cannot extract a session until it verifies the phone's confirmation and
an encrypted neutral-ready frame; the phone cannot extract one until the
desktop's confirmation verifies. No CLI command or Android screen invokes this
flow yet. `protocol/tests/pairing_flow.rs` exercises it entirely in memory.

## Continuous integration

[.github/workflows/ci.yml](.github/workflows/ci.yml) runs on pushes to `main`,
pull requests targeting `main`, and manual runs from GitHub's Actions tab.

- **Rust:** formatting on Linux, plus Clippy and workspace/documentation tests
  on Linux, macOS, and Windows. Dependency resolution uses `Cargo.lock`.
- **Android:** Java 17, the checked-in Gradle wrapper, Android SDK 37, unit
  tests, lint, debug and unsigned release builds, and instrumentation-test
  compilation.
- **Android emulator:** executes the Compose launch test on an API 35 emulator.
  This is a UI smoke test; Wi-Fi, Bluetooth, touch latency, and gamepad backend
  compatibility still require the physical-device tests in the plan.

The pipeline uploads test/lint reports and the debug APK as seven-day workflow
artifacts. It uses read-only repository permissions, dependency caches, pinned
action revisions, and cancels superseded runs. It does not publish releases or
require release-signing secrets.

## Scope note

The pinned PAKE has no weaker authentication fallback. Pairing remains
unavailable to users until the real phone consent flow, bounded transport, and
global/per-source request limits are implemented and tested. Do not use this
build to transmit real input. Nothing is wired to a network or gamepad backend,
and no measured memory ceiling or gameplay compatibility is claimed.
The next milestones from the implementation plan are:

1. Bounded pairing TCP transport, rate limits, and Android consent/token UI.
2. Security/ABI validation, resume MAC, shared JNI boundary, LAN permissions,
   discovery, and desktop daemon/IPC.
3. Custom multi-touch controller View/Canvas and the Compose layout editor.

See [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for the full P0/P1 gates and
acceptance criteria.
